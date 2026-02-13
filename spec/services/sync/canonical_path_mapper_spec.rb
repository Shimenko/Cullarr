require "rails_helper"

RSpec.describe Sync::CanonicalPathMapper, type: :service do
  let(:integration) do
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Mapper",
      base_url: "https://sonarr.mapper.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  it "maps an exact prefix match" do
    PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/data")).to eq("/mnt")
  end

  it "maps when the path matches the prefix boundary" do
    PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/data/tv/show.mkv")).to eq("/mnt/tv/show.mkv")
  end

  it "does not map similarly-prefixed non-boundary paths" do
    PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/database/tv/show.mkv")).to eq("/database/tv/show.mkv")
  end

  it "keeps deterministic tie-breaking for equal-strength prefixes" do
    first = PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt-a")
    second = PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt-b")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/data/tv/show.mkv")).to eq("/mnt-a/tv/show.mkv")
    expect(first.id).to be < second.id
  end

  it "maps nested absolute paths when root prefix mapping is configured" do
    PathMapping.create!(integration:, from_prefix: "/", to_prefix: "/mnt")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/shows/show.mkv")).to eq("/mnt/shows/show.mkv")
  end

  it "maps exact root path when root prefix mapping is configured" do
    PathMapping.create!(integration:, from_prefix: "/", to_prefix: "/mnt")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/")).to eq("/mnt")
  end

  it "does not apply root mapping to non-absolute paths" do
    PathMapping.create!(integration:, from_prefix: "/", to_prefix: "/mnt")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("show.mkv")).to eq("show.mkv")
  end

  it "normalizes trailing slash variants for root mappings before canonicalizing" do
    PathMapping.create!(integration:, from_prefix: "//", to_prefix: "/mnt/")

    mapper = described_class.new(integration:)
    expect(mapper.canonicalize("/movies/test.mkv")).to eq("/mnt/movies/test.mkv")
  end
end
