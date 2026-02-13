require "rails_helper"

RSpec.describe Paths::ManagedRootClassifier, type: :service do
  it "classifies a path under a managed root as managed" do
    classifier = described_class.new(managed_path_roots: [ "/mnt/media" ])

    result = classifier.classify("/mnt/media/movies/example.mkv")

    expect(result).to eq(
      normalized_path: "/mnt/media/movies/example.mkv",
      ownership: "managed",
      matched_managed_root: "/mnt/media"
    )
  end

  it "classifies unmatched paths as external" do
    classifier = described_class.new(managed_path_roots: [ "/mnt/media" ])

    result = classifier.classify("/external/media/movies/example.mkv")

    expect(result).to eq(
      normalized_path: "/external/media/movies/example.mkv",
      ownership: "external",
      matched_managed_root: nil
    )
  end

  it "classifies non-absolute candidate paths as external" do
    classifier = described_class.new(managed_path_roots: [ "/" ])

    result = classifier.classify("movies/example.mkv")

    expect(result).to eq(
      normalized_path: "movies/example.mkv",
      ownership: "external",
      matched_managed_root: nil
    )
  end

  it "uses the longest matching managed root" do
    classifier = described_class.new(managed_path_roots: [ "/mnt", "/mnt/media" ])

    result = classifier.classify("/mnt/media/movies/example.mkv")

    expect(result.fetch(:matched_managed_root)).to eq("/mnt/media")
  end
end
