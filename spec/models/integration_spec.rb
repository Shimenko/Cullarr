require "rails_helper"
require "base64"
require "securerandom"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Integration, type: :model do
  def random_encryption_key
    Base64.strict_encode64(SecureRandom.random_bytes(32))
  end

  it "requires an api key on create" do
    integration = described_class.new(
      kind: "sonarr",
      name: "Sonarr",
      base_url: "https://sonarr.local",
      verify_ssl: true
    )

    expect(integration).not_to be_valid
    expect(integration.errors[:api_key]).to include("can't be blank")
  end

  it "normalizes trailing slash from base_url" do
    integration = described_class.create!(
      kind: "radarr",
      name: "Radarr",
      base_url: "https://radarr.local/",
      api_key: "secret-key",
      verify_ssl: true
    )

    expect(integration.base_url).to eq("https://radarr.local")
  end

  it "rejects invalid URL schemes" do
    integration = described_class.new(
      kind: "tautulli",
      name: "Tautulli",
      base_url: "ftp://tautulli.local",
      api_key: "secret-key",
      verify_ssl: true
    )

    expect(integration).not_to be_valid
    expect(integration.errors[:base_url]).to include("base_url must use http or https")
  end

  it "returns api payload without cleartext api key" do
    integration = described_class.create!(
      kind: "sonarr",
      name: "Sonarr",
      base_url: "https://sonarr.local",
      api_key: "secret-key",
      verify_ssl: true
    )

    payload = integration.as_api_json
    expect(payload).to include(:id, :kind, :name, :base_url, :status)
    expect(payload[:api_key_present]).to be(true)
    expect(payload[:tuning]).to include(
      request_timeout_seconds: 15,
      retry_max_attempts: 5,
      sonarr_fetch_workers: 4,
      sonarr_fetch_workers_resolved: 4,
      radarr_moviefile_fetch_workers: 4,
      radarr_moviefile_fetch_workers_resolved: 4,
      tautulli_history_page_size: 500,
      tautulli_metadata_workers: 4,
      tautulli_metadata_workers_resolved: 4
    )
    expect(payload).not_to have_key(:api_key)
  end

  it "clamps integration tuning settings to safe bounds" do
    integration = described_class.create!(
      kind: "tautulli",
      name: "Tautulli Tuned",
      base_url: "https://tautulli.tuned.local",
      api_key: "secret-key",
      verify_ssl: true,
      settings_json: {
        "request_timeout_seconds" => 500,
        "retry_max_attempts" => 0,
        "sonarr_fetch_workers" => 99,
        "radarr_moviefile_fetch_workers" => -5,
        "tautulli_history_page_size" => 9_999,
        "tautulli_metadata_workers" => 999
      }
    )

    expect(integration.request_timeout_seconds).to eq(120)
    expect(integration.retry_max_attempts).to eq(1)
    expect(integration.sonarr_fetch_workers).to eq(64)
    expect(integration.radarr_moviefile_fetch_workers).to eq(0)
    expect(integration.tautulli_history_page_size).to eq(5000)
    expect(integration.tautulli_metadata_workers).to eq(64)
  end

  it "supports auto worker mode when worker setting is zero" do
    allow(Etc).to receive(:nprocessors).and_return(24)

    integration = described_class.create!(
      kind: "tautulli",
      name: "Tautulli Auto Workers",
      base_url: "https://tautulli.auto.local",
      api_key: "secret-key",
      verify_ssl: true,
      settings_json: {
        "sonarr_fetch_workers" => 0,
        "radarr_moviefile_fetch_workers" => 0,
        "tautulli_metadata_workers" => 0
      }
    )

    expect(integration.sonarr_fetch_workers).to eq(0)
    expect(integration.radarr_moviefile_fetch_workers).to eq(0)
    expect(integration.tautulli_metadata_workers).to eq(0)
    expect(integration.sonarr_fetch_workers_resolved).to eq(23)
    expect(integration.radarr_moviefile_fetch_workers_resolved).to eq(23)
    expect(integration.tautulli_metadata_workers_resolved).to eq(23)
  end

  it "stores api key encrypted at rest" do
    integration = described_class.create!(
      kind: "sonarr",
      name: "Sonarr Encrypted",
      base_url: "https://sonarr.encrypted.local",
      api_key: "secret-key",
      verify_ssl: true
    )

    stored_value = integration.read_attribute_before_type_cast("api_key_ciphertext")
    expect(stored_value).to be_present
    expect(stored_value).not_to include("secret-key")
  end

  it "re-encrypts api key with the active primary key while preserving plaintext" do
    original_primary_keys = ActiveRecord::Encryption.config.primary_key
    old_key = random_encryption_key
    new_key = random_encryption_key

    ActiveRecord::Encryption.config.primary_key = [ old_key ]
    integration = described_class.create!(
      kind: "sonarr",
      name: "Sonarr Rotated",
      base_url: "https://sonarr.rotated.local",
      api_key: "rotate-me",
      verify_ssl: true
    )
    old_ciphertext = integration.read_attribute_before_type_cast("api_key_ciphertext")

    ActiveRecord::Encryption.config.primary_key = [ old_key, new_key ]
    rotated = integration.rotate_api_key_ciphertext!
    integration.reload

    expect(rotated).to be(true)
    expect(integration.api_key).to eq("rotate-me")
    expect(integration.read_attribute_before_type_cast("api_key_ciphertext")).not_to eq(old_ciphertext)
  ensure
    ActiveRecord::Encryption.config.primary_key = original_primary_keys
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
