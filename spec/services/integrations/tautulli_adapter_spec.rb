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

  it "normalizes users, history rows, and metadata payloads" do
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
          [ 200, {}, fixture_json("tautulli/get_history_page.json") ]
        when "get_metadata"
          expect(env.params["rating_key"]).to eq("plex-movie-701")
          [ 200, {}, fixture_json("tautulli/get_metadata.json") ]
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
    expect(page[:records_total]).to eq(2)
    expect(page[:rows].first).to include(history_id: 1001, media_type: "movie", plex_rating_key: "plex-movie-701")
    expect(metadata).to include(duration_ms: 7_260_000, plex_guid: "plex://movie/701")
    stubs.verify_stubbed_calls
  end

  it "raises ContractMismatchError for unsupported history media types" do
    bad_payload = {
      response: {
        result: "success",
        data: {
          recordsFiltered: 1,
          data: [ { id: 1, user_id: 2, media_type: "artist", rating_key: "x", date: 1 } ]
        }
      }
    }.to_json

    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("api/v2") { [ 200, {}, bad_payload ] }
    end
    adapter = described_class.new(integration:, connection: test_connection(stubs))

    expect do
      adapter.fetch_history_page(start: 0, length: 10, order_column: "id", order_dir: "desc")
    end.to raise_error(Integrations::ContractMismatchError)
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
