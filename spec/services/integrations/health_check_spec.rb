require "rails_helper"

# rubocop:disable RSpec/ExampleLength
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
    adapter = instance_double(Integrations::SonarrAdapter)
    allow(Integrations::AdapterFactory).to receive(:for).with(integration:).and_return(adapter)
    allow(adapter).to receive(:check_health!).and_raise(
      Integrations::UnsupportedVersionError.new(
        "integration version is unsupported",
        details: { reported_version: "3.0.0" }
      )
    )

    result = described_class.new(integration).call

    expect(result[:status]).to eq("unsupported")
    expect(integration.reload.status).to eq("unsupported")
    expect(integration.supported_for_delete?).to be(false)
  end

  it "raises unsupported errors when requested by caller" do
    adapter = instance_double(Integrations::SonarrAdapter)
    allow(Integrations::AdapterFactory).to receive(:for).with(integration:).and_return(adapter)
    allow(adapter).to receive(:check_health!).and_raise(
      Integrations::UnsupportedVersionError.new(
        "integration version is unsupported",
        details: { reported_version: "3.0.0" }
      )
    )

    expect do
      described_class.new(integration, raise_on_unsupported: true).call
    end.to raise_error(Integrations::UnsupportedVersionError)
  end

  it "requests ARR health endpoint relative to base_url path prefix" do
    adapter = instance_double(Integrations::SonarrAdapter)
    allow(Integrations::AdapterFactory).to receive(:for).with(integration:).and_return(adapter)
    allow(adapter).to receive(:check_health!).and_return(
      {
        status: "healthy",
        reported_version: "4.0.1",
        supported_for_delete: true,
        warnings: []
      }
    )

    result = described_class.new(integration).call

    expect(result[:status]).to eq("healthy")
    expect(integration.reload.reported_version).to eq("4.0.1")
  end

  context "when warn_only_read_only mode is enabled" do
    let(:compatibility_mode) { "warn_only_read_only" }

    it "marks unsupported version as warning" do
      adapter = instance_double(Integrations::SonarrAdapter)
      allow(Integrations::AdapterFactory).to receive(:for).with(integration:).and_return(adapter)
      allow(adapter).to receive(:check_health!).and_return(
        {
          status: "warning",
          reported_version: "3.0.0",
          supported_for_delete: false,
          warnings: [ "unsupported version running in warn-only read mode" ]
        }
      )

      result = described_class.new(integration).call

      expect(result[:status]).to eq("warning")
      expect(integration.reload.status).to eq("warning")
    end
  end
end
# rubocop:enable RSpec/ExampleLength
