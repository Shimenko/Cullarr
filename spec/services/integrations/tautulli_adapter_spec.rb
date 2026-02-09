require "rails_helper"

# rubocop:disable RSpec/ExampleLength
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
      stub.get("api/v2") do
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
        case env.params["cmd"]
        when "get_users"
          [ 200, {}, fixture_json("tautulli/get_users.json") ]
        when "get_history"
          [ 200, {}, fixture_json("tautulli/get_history_page.json") ]
        when "get_metadata"
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
