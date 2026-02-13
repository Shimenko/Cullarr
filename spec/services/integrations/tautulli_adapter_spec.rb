require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Integrations::TautulliAdapter, type: :service do
  let(:integration) do
    Integration.create!(
      kind: "tautulli",
      name: "Tautulli Adapter",
      base_url: "https://tautulli.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  it "returns healthy check payload for supported versions" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["apikey"]).to eq("secret")
        expect(env.params["cmd"]).to eq("get_tautulli_info")
        [ 200, {}, fixture_json("tautulli/get_tautulli_info.json") ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.check_health!

    expect(result).to include(status: "healthy", supported_for_delete: true, reported_version: "2.13.4")
    stubs.verify_stubbed_calls
  end

  it "normalizes users, history rows, and rich metadata payloads with provenance" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["apikey"]).to eq("secret")
        case env.params["cmd"]
        when "get_users"
          [ 200, {}, fixture_json("tautulli/get_users.json") ]
        when "get_history"
          expect(env.params["start"]).to eq("0")
          expect(env.params["length"]).to eq("50")
          expect(env.params["order_column"]).to eq("id")
          expect(env.params["order_dir"]).to eq("desc")
          expect(env.params["include_activity"]).to eq("0")
          [ 200, {}, fixture_json("tautulli/get_history_page.json") ]
        when "get_metadata"
          expect(env.params["rating_key"]).to eq("plex-movie-701")
          [ 200, {}, fixture_json("tautulli/get_metadata_rich.json") ]
        else
          [ 500, {}, "{}" ]
        end
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    users = adapter.fetch_users
    page = adapter.fetch_history_page(start: 0, length: 50, order_column: "id", order_dir: "desc")
    metadata = adapter.fetch_metadata(rating_key: "plex-movie-701")

    expect(users.first).to include(tautulli_user_id: 10, friendly_name: "Alice", is_hidden: false)
    expect(users.last).to include(tautulli_user_id: 11, is_hidden: true)
    expect(page[:rows].size).to eq(2)
    expect(page[:raw_rows_count]).to eq(2)
    expect(page[:rows_skipped_invalid]).to eq(0)
    expect(page[:records_total]).to eq(2)
    expect(page[:rows].first).to include(history_id: 1001, media_type: "movie", plex_rating_key: "plex-movie-701")
    expect(metadata).to include(
      duration_ms: 7_260_000,
      plex_guid: "plex://movie/701",
      file_path: "/mnt/media/movies/Example Movie (2024)/movie.mkv"
    )
    expect(metadata.fetch(:external_ids)).to include(
      imdb_id: "tt555001",
      tmdb_id: 555001,
      tvdb_id: 990_701
    )
    provenance = metadata.fetch(:provenance)
    expect(provenance).to include(
      endpoint: "get_metadata",
      feed_role: "enrichment_verification",
      source_strength: "strong_enrichment",
      integration_name: integration.name,
      integration_kind: integration.kind,
      integration_id: integration.id
    )
    expect(provenance.fetch(:signals).fetch(:file_path)).to include(
      source: "metadata_media_info_parts_file",
      value: "/mnt/media/movies/Example Movie (2024)/movie.mkv"
    )
    expect(provenance.fetch(:signals).fetch(:imdb_id)).to include(source: "metadata_guids", value: "tt555001")
    expect(provenance.fetch(:signals).fetch(:tmdb_id)).to include(source: "metadata_guids", value: 555001)
    expect(provenance.fetch(:signals).fetch(:tvdb_id)).to include(source: "metadata_top_level", value: 990_701)
    stubs.verify_stubbed_calls
  end

  it "normalizes sparse library media pages as discovery feed rows" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["apikey"]).to eq("secret")
        case env.params["cmd"]
        when "get_libraries"
          [ 200, {}, fixture_json("tautulli/get_libraries.json") ]
        when "get_library_media_info"
          expect(env.params["section_id"]).to eq("10")
          expect(env.params["start"]).to eq("0")
          expect(env.params["length"]).to eq("50")
          [ 200, {}, fixture_json("tautulli/get_library_media_info_page_sparse.json") ]
        else
          [ 500, {}, "{}" ]
        end
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    libraries = adapter.fetch_libraries
    page = adapter.fetch_library_media_page(library_id: 10, start: 0, length: 50)

    expect(libraries).to include(include(library_id: 10, title: "Movies"))
    expect(page[:rows].size).to eq(2)
    expect(page[:raw_rows_count]).to eq(3)
    expect(page[:rows_skipped_invalid]).to eq(1)
    expect(page[:rows].first).to include(
      media_type: "movie",
      plex_rating_key: "plex-movie-sparse-111",
      title: "Sparse Movie",
      year: 2024,
      plex_added_at: "2023-11-14T22:13:20Z"
    )
    expect(page[:rows].first.fetch(:provenance)).to include(
      endpoint: "get_library_media_info",
      feed_role: "discovery",
      source_strength: "sparse_discovery",
      integration_name: integration.name,
      integration_kind: integration.kind,
      integration_id: integration.id
    )
    expect(page[:rows].last).to include(media_type: "episode", plex_rating_key: "plex-episode-sparse-222")
    stubs.verify_stubbed_calls
  end

  it "extracts external ids from guids and encodes absent file-path signal as none" do
    payload = {
      response: {
        result: "success",
        data: {
          duration: 4_359_000,
          guid: "plex://episode/5fbe1bb5dcbaf9002f9ddf63",
          imdb_id: nil,
          tmdb_id: nil,
          tvdb_id: nil,
          guids: [ "imdb://tt5109276", "tmdb://1132654", "tvdb://5343660" ]
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["cmd"]).to eq("get_metadata")
        expect(env.params["rating_key"]).to eq("1290")
        [ 200, {}, payload ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    metadata = adapter.fetch_metadata(rating_key: "1290")

    expect(metadata).to include(duration_ms: 4_359_000, plex_guid: "plex://episode/5fbe1bb5dcbaf9002f9ddf63")
    expect(metadata.fetch(:external_ids)).to include(
      imdb_id: "tt5109276",
      tmdb_id: 1_132_654,
      tvdb_id: 5_343_660
    )
    expect(metadata[:file_path]).to be_nil
    expect(metadata.dig(:provenance, :signals, :file_path)).to eq(
      source: "none",
      raw: nil,
      normalized: nil,
      value: nil
    )
    expect(metadata.dig(:provenance, :signals, :imdb_id, :source)).to eq("metadata_guids")
    stubs.verify_stubbed_calls
  end

  it "falls back to top-level metadata id keys when guids are missing or invalid" do
    payload = {
      response: {
        result: "success",
        data: {
          duration: 1_234_000,
          guid: "plex://movie/4242",
          guids: [ "invalid://value", "tmdb://not-a-number" ],
          imdbId: "tt4242424",
          tmdb_id: "4242",
          tvdbId: "9090"
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["cmd"]).to eq("get_metadata")
        expect(env.params["rating_key"]).to eq("4242")
        [ 200, {}, payload ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    metadata = adapter.fetch_metadata(rating_key: "4242")

    expect(metadata.fetch(:external_ids)).to eq(
      imdb_id: "tt4242424",
      tmdb_id: 4_242,
      tvdb_id: 9_090
    )
    expect(metadata.dig(:provenance, :signals, :imdb_id, :source)).to eq("metadata_top_level")
    expect(metadata.dig(:provenance, :signals, :tmdb_id, :source)).to eq("metadata_top_level")
    expect(metadata.dig(:provenance, :signals, :tvdb_id, :source)).to eq("metadata_top_level")
    stubs.verify_stubbed_calls
  end

  it "keeps absent id signals with source none instead of omitting signal keys" do
    payload = {
      response: {
        result: "success",
        data: {
          duration: 999_000,
          guid: "plex://movie/9999"
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["cmd"]).to eq("get_metadata")
        expect(env.params["rating_key"]).to eq("9999")
        [ 200, {}, payload ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    metadata = adapter.fetch_metadata(rating_key: "9999")

    expect(metadata.fetch(:external_ids)).to eq({})
    expect(metadata.fetch(:provenance).fetch(:signals)).to include(
      file_path: { source: "none", raw: nil, normalized: nil, value: nil },
      imdb_id: { source: "none", raw: nil, normalized: nil, value: nil },
      tmdb_id: { source: "none", raw: nil, normalized: nil, value: nil },
      tvdb_id: { source: "none", raw: nil, normalized: nil, value: nil }
    )
    stubs.verify_stubbed_calls
  end

  it "tolerates malformed nested media_info and parts entries without crashing" do
    payload = {
      response: {
        result: "success",
        data: {
          duration: 1_000_000,
          guid: "plex://movie/5000",
          media_info: [
            1,
            { parts: [ 2, { file: 99 }, { file: "   " }, { file: "/mnt/media/movies/Malformed Safe/movie.mkv" } ] },
            { parts: "not-an-array" }
          ],
          guids: [ "imdb://tt5000500" ]
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") do |env|
        expect(env.params["cmd"]).to eq("get_metadata")
        expect(env.params["rating_key"]).to eq("5000")
        [ 200, {}, payload ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    metadata = adapter.fetch_metadata(rating_key: "5000")

    expect(metadata[:file_path]).to eq("/mnt/media/movies/Malformed Safe/movie.mkv")
    expect(metadata.fetch(:external_ids)).to eq(imdb_id: "tt5000500")
    expect(metadata.dig(:provenance, :signals, :file_path, :source)).to eq("metadata_media_info_parts_file")
    stubs.verify_stubbed_calls
  end

  it "skips unsupported history media types" do
    bad_payload = {
      response: {
        result: "success",
        data: {
          recordsFiltered: 2,
          data: [
            { id: 1, user_id: 2, media_type: "artist", rating_key: "x", date: 1 },
            { id: 2, user_id: 2, media_type: "movie", rating_key: "movie-2", date: 2 }
          ]
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 200, {}, bad_payload ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    page = adapter.fetch_history_page(start: 0, length: 10, order_column: "id", order_dir: "desc")

    expect(page[:rows].size).to eq(1)
    expect(page[:rows].first[:history_id]).to eq(2)
    expect(page[:rows_skipped_invalid]).to eq(1)
  end

  it "uses row_id and reference_id when id is unavailable" do
    payload = {
      response: {
        result: "success",
        data: {
          recordsFiltered: 3,
          data: [
            { id: nil, row_id: 501, reference_id: nil, user_id: 10, media_type: "movie", rating_key: "m-1", date: 1 },
            { id: nil, row_id: nil, reference_id: 502, user_id: 10, media_type: "episode", rating_key: "e-1", date: 2 },
            { id: nil, row_id: nil, reference_id: nil, user_id: 10, media_type: "movie", rating_key: "m-2", date: 3 }
          ]
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 200, {}, payload ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    page = adapter.fetch_history_page(start: 0, length: 10, order_column: "id", order_dir: "desc")

    expect(page[:rows].map { |row| row[:history_id] }).to eq([ 501, 502 ])
    expect(page[:rows_skipped_invalid]).to eq(1)
  end

  it "maps malformed JSON payloads to ContractMismatchError" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 200, {}, "{bad-json}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.fetch_users }.to raise_error(Integrations::ContractMismatchError, "integration returned malformed JSON")
  end

  it "maps unexpected client errors to ContractMismatchError with status details" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 400, {}, '{"response":{"result":"error","message":"bad"}}' ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect do
      adapter.fetch_users
    end.to raise_error(Integrations::ContractMismatchError) do |error|
      expect(error.details[:status]).to eq(400)
    end
  end

  it "maps authentication failures to AuthError" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 401, {}, "{}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.fetch_users }.to raise_error(Integrations::AuthError)
  end

  it "maps rate-limited responses to RateLimitedError" do
    integration.update!(settings_json: integration.settings_json.merge("retry_max_attempts" => 1))
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 429, { "Retry-After" => "1" }, "{}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.fetch_users }.to raise_error(Integrations::RateLimitedError)
  end

  def test_connection(stubs)
    Faraday.new(url: integration.base_url) do |builder|
      builder.adapter :test, stubs
    end
  end

  def fixture_json(path)
    Rails.root.join("spec/fixtures/integrations/#{path}").read
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
