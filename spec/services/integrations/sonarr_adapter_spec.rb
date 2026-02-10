require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Integrations::SonarrAdapter, type: :service do
  let(:integration) do
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Adapter",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  it "returns healthy check payload for supported versions" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/system/status") do
        [ 200, {}, fixture_json("sonarr/system_status.json") ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.check_health!

    expect(result).to include(status: "healthy", supported_for_delete: true, reported_version: "4.0.5")
    stubs.verify_stubbed_calls
  end

  it "normalizes series/episodes/file payloads" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/series") { [ 200, {}, fixture_json("sonarr/series.json") ] }
      stub.get("api/v3/episode") do |env|
        expect(env.params["seriesId"]).to eq("101")
        [ 200, {}, fixture_json("sonarr/episodes_101.json") ]
      end
      stub.get("api/v3/episodefile") do |env|
        expect(env.params["seriesId"]).to eq("101")
        [ 200, {}, fixture_json("sonarr/episode_files_101.json") ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    series = adapter.fetch_series
    episodes = adapter.fetch_episodes(series_id: 101)
    files = adapter.fetch_episode_files(series_id: 101)

    expect(series.first).to include(sonarr_series_id: 101, title: "Example Show")
    expect(episodes.first).to include(sonarr_episode_id: 5001, season_number: 1, duration_ms: 3_000_000)
    expect(files.first).to include(arr_file_id: 9001, sonarr_episode_id: 5001, size_bytes: 734_003_200)
    stubs.verify_stubbed_calls
  end

  it "maps authentication failures to AuthError" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/system/status") { [ 401, {}, "{}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.check_health! }.to raise_error(Integrations::AuthError)
  end

  it "maps unexpected client errors to ContractMismatchError with status details" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/series") { [ 400, {}, '{"message":"bad request"}' ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect do
      adapter.fetch_series
    end.to raise_error(Integrations::ContractMismatchError) do |error|
      expect(error.details[:status]).to eq(400)
    end
  end

  it "maps malformed JSON payloads to ContractMismatchError" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/series") { [ 200, {}, "{not-json}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.fetch_series }.to raise_error(Integrations::ContractMismatchError, "integration returned malformed JSON")
  end

  it "maps service unavailable responses to ConnectivityError" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/series") { [ 503, {}, '{"message":"service unavailable"}' ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect { adapter.fetch_series }.to raise_error(Integrations::ConnectivityError)
  end

  it "treats already-missing episode files as deleted for idempotency" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.delete("api/v3/episodefile/9001") { [ 404, {}, "{}" ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.delete_episode_file!(arr_file_id: 9001)

    expect(result).to include(deleted: true, already_deleted: true)
  end

  it "resolves existing tags and creates missing tags" do
    existing_stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/tag") { [ 200, {}, '[{"id":12,"label":"cullarr:culled"}]' ] }
    end
    existing_adapter = described_class.new(integration:, connection: test_connection(existing_stubs))
    expect(existing_adapter.ensure_tag!(name: "cullarr:culled")).to eq(arr_tag_id: 12)

    create_stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/tag") { [ 200, {}, "[]" ] }
      stub.post("api/v3/tag") { [ 200, {}, '{"id":33}' ] }
    end
    create_adapter = described_class.new(integration:, connection: test_connection(create_stubs))
    expect(create_adapter.ensure_tag!(name: "cullarr:culled")).to eq(arr_tag_id: 33)
  end

  it "adds a series tag without dropping existing tags" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/series/101") { [ 200, {}, '{"id":101,"title":"Example","tags":[1]}' ] }
      stub.put("api/v3/series/101") do |env|
        payload = JSON.parse(env.body)
        expect(payload.fetch("tags")).to contain_exactly(1, 2)
        [ 200, {}, "{}" ]
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.add_series_tag!(sonarr_series_id: 101, arr_tag_id: 2)

    expect(result).to eq(updated: true)
  end

  it "retries transient rate limits up to retry_max_attempts" do
    integration.update!(settings_json: integration.settings_json.merge("retry_max_attempts" => 2))
    attempts = 0

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v3/system/status") do
        attempts += 1
        if attempts == 1
          [ 429, { "Retry-After" => "0" }, "{}" ]
        else
          [ 200, {}, fixture_json("sonarr/system_status.json") ]
        end
      end
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    result = adapter.check_health!

    expect(result).to include(status: "healthy")
    expect(attempts).to eq(2)
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
# rubocop:enable RSpec/ExampleLength
