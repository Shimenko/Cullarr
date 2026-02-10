require "rails_helper"

RSpec.describe Integrations::RadarrAdapter, type: :service do
  let(:integration) do
    Integration.create!(
      kind: "radarr",
      name: "Radarr Adapter",
      base_url: "https://radarr.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  it "returns healthy check payload for supported versions" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/system/status") do
        [ 200, {}, fixture_json("radarr/system_status.json") ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.check_health!

    expect(result).to include(status: "healthy", supported_for_delete: true, reported_version: "6.0.4")
    stubs.verify_stubbed_calls
  end

  # rubocop:disable RSpec/ExampleLength
  it "normalizes movie and movie-file payloads" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/movie") do |env|
        expect(env.params["includeMovieFile"]).to eq("true")
        [ 200, {}, fixture_json("radarr/movies.json") ]
      end
      stub.get("api/v3/moviefile") do |env|
        expect(env.params["movieId"]).to eq("701")
        [ 200, {}, fixture_json("radarr/movie_files.json") ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    movies = adapter.fetch_movies
    files = adapter.fetch_movie_files(movie_id: 701)

    expect(movies.first).to include(radarr_movie_id: 701, title: "Example Movie", duration_ms: 7_260_000)
    expect(files.first).to include(arr_file_id: 8001, radarr_movie_id: 701, size_bytes: 3_221_225_472)
    stubs.verify_stubbed_calls
  end
  # rubocop:enable RSpec/ExampleLength

  it "maps unexpected client errors to ContractMismatchError with status details" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/moviefile") { [ 400, {}, '{"message":"movieId required"}' ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect do
      adapter.fetch_movie_files(movie_id: 701)
    end.to raise_error(Integrations::ContractMismatchError) do |error|
      expect(error.details[:status]).to eq(400)
    end
  end

  it "maps service unavailable responses to ConnectivityError" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/movie") { [ 503, {}, '{"message":"service unavailable"}' ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.fetch_movies }.to raise_error(Integrations::ConnectivityError)
  end

  it "treats already-missing movie files as deleted for idempotency" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.delete("api/v3/moviefile/8001") { [ 404, {}, "{}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.delete_movie_file!(arr_file_id: 8001)

    expect(result).to include(deleted: true, already_deleted: true)
  end

  it "applies tags while preserving existing movie tags" do
    stubs, captured_tags = build_movie_tag_update_stubs
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.add_movie_tag!(radarr_movie_id: 701, arr_tag_id: 2)

    expect(result).to eq(updated: true)
    expect(captured_tags.call).to contain_exactly(1, 2)
  end

  def test_connection(stubs)
    Faraday.new(url: integration.base_url) do |builder|
      builder.adapter :test, stubs
    end
  end

  def fixture_json(path)
    Rails.root.join("spec/fixtures/integrations/#{path}").read
  end

  def build_movie_tag_update_stubs
    tags = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/movie/701") { [ 200, {}, '{"id":701,"title":"Movie","tags":[1]}' ] }
      stub.put("api/v3/movie/701") do |env|
        tags = JSON.parse(env.body).fetch("tags")
        [ 200, {}, "{}" ]
      end
    end
    [ stubs, -> { tags } ]
  end
end
