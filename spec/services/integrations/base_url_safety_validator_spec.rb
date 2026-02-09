require "rails_helper"

RSpec.describe Integrations::BaseUrlSafetyValidator, type: :service do
  it "accepts http/https URLs when allow policy is not configured" do
    expect(described_class.validate!("https://sonarr.local", env: {})).to be(true)
  end

  it "rejects non-http schemes" do
    expect do
      described_class.validate!("ftp://sonarr.local", env: {})
    end.to raise_error(Integrations::UnsafeBaseUrlError)
  end

  it "rejects hosts outside configured allowed hosts" do
    expect do
      described_class.validate!(
        "https://tautulli.local",
        env: { "CULLARR_ALLOWED_INTEGRATION_HOSTS" => "sonarr.local,radarr.local" }
      )
    end.to raise_error(Integrations::UnsafeBaseUrlError)
  end

  it "accepts hosts in configured allowed hosts" do
    expect(
      described_class.validate!(
        "https://sonarr.local",
        env: { "CULLARR_ALLOWED_INTEGRATION_HOSTS" => "sonarr.local,radarr.local" }
      )
    ).to be(true)
  end

  it "accepts true wildcard host patterns" do
    expect(
      described_class.validate!(
        "https://radarr.local",
        env: { "CULLARR_ALLOWED_INTEGRATION_HOSTS" => "*.local,sonarr-*" }
      )
    ).to be(true)
  end

  it "accepts global wildcard host pattern when explicitly configured" do
    expect(
      described_class.validate!(
        "https://anything.example",
        env: { "CULLARR_ALLOWED_INTEGRATION_HOSTS" => "*" }
      )
    ).to be(true)
  end

  it "accepts hostnames that resolve into configured allowed network ranges" do
    allow(Resolv).to receive(:each_address).with("sonarr.local").and_return([ "192.168.1.10" ])

    expect(
      described_class.validate!(
        "https://sonarr.local",
        env: { "CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES" => "192.168.1.0/24" }
      )
    ).to be(true)
  end

  it "rejects invalid allowed network ranges configuration" do
    expect do
      described_class.validate!(
        "https://sonarr.local",
        env: { "CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES" => "not-a-cidr" }
      )
    end.to raise_error(Integrations::UnsafeBaseUrlError)
  end
end
