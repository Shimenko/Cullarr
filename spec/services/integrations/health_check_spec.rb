require "rails_helper"

RSpec.describe Integrations::HealthCheck, type: :service do
  let(:integration) do
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: settings_json
    )
  end
  let(:settings_json) { { "compatibility_mode" => compatibility_mode } }
  let(:compatibility_mode) { "strict_latest" }

  it "marks unsupported version in strict mode" do
    connection = instance_double(Faraday::Connection)
    response = instance_double(Faraday::Response, status: 200, body: { version: "3.0.0" }.to_json)
    allow(Faraday).to receive(:new).and_return(connection)
    allow(connection).to receive(:get).and_return(response)

    result = described_class.new(integration).call

    expect(result[:status]).to eq("unsupported")
    expect(integration.reload.status).to eq("unsupported")
    expect(integration.supported_for_delete?).to be(false)
  end

  it "requests ARR health endpoint relative to base_url path prefix" do
    integration.update!(base_url: "https://sonarr.local/proxy")
    connection = instance_double(Faraday::Connection)
    response = instance_double(Faraday::Response, status: 200, body: { version: "4.0.1" }.to_json)
    allow(Faraday).to receive(:new).and_return(connection)
    allow(connection).to receive(:get).with("api/v3/system/status").and_return(response)

    described_class.new(integration).call

    expect(connection).to have_received(:get).with("api/v3/system/status")
  end

  context "when warn_only_read_only mode is enabled" do
    let(:compatibility_mode) { "warn_only_read_only" }

    it "marks unsupported version as warning" do
      connection = instance_double(Faraday::Connection)
      response = instance_double(Faraday::Response, status: 200, body: { version: "3.0.0" }.to_json)
      allow(Faraday).to receive(:new).and_return(connection)
      allow(connection).to receive(:get).and_return(response)

      result = described_class.new(integration).call

      expect(result[:status]).to eq("warning")
      expect(integration.reload.status).to eq("warning")
    end
  end
end
