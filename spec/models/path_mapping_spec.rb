require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe PathMapping, type: :model do
  it "normalizes prefixes before validation" do
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr",
      base_url: "https://sonarr.local",
      api_key: "secret-key",
      verify_ssl: true
    )

    mapping = described_class.create!(
      integration: integration,
      from_prefix: "/data//tv/",
      to_prefix: "\\mnt\\tv\\"
    )

    expect(mapping.from_prefix).to eq("/data/tv")
    expect(mapping.to_prefix).to eq("/mnt/tv")
  end

  it "deduplicates normalized mappings per integration" do
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr",
      base_url: "https://sonarr.local",
      api_key: "secret-key",
      verify_ssl: true
    )
    described_class.create!(integration: integration, from_prefix: "/data/tv", to_prefix: "/mnt/tv")

    duplicate = described_class.new(integration: integration, from_prefix: "/data//tv/", to_prefix: "/mnt/tv/")
    expect(duplicate).not_to be_valid
  end
end
# rubocop:enable RSpec/ExampleLength
