require "rails_helper"

RSpec.describe Paths::PrefixMatcher, type: :service do
  describe ".boundary_match?" do
    it "matches exact prefix" do
      expect(described_class.boundary_match?(path: "/data", prefix: "/data")).to be(true)
    end

    it "matches nested boundary path" do
      expect(described_class.boundary_match?(path: "/data/tv/show.mkv", prefix: "/data")).to be(true)
    end

    it "does not match non-boundary similarly-prefixed path" do
      expect(described_class.boundary_match?(path: "/database/tv/show.mkv", prefix: "/data")).to be(false)
    end

    it "matches root prefix only for absolute paths" do
      expect(described_class.boundary_match?(path: "/movies/test.mkv", prefix: "/")).to be(true)
      expect(described_class.boundary_match?(path: "movies/test.mkv", prefix: "/")).to be(false)
    end
  end

  describe ".best_match" do
    it "returns the longest matching prefix" do
      match = described_class.best_match(path: "/media/movies/Example/test.mkv", candidates: [ "/media", "/media/movies" ])

      expect(match).to eq("/media/movies")
    end

    it "keeps deterministic input-order tie break for equal-strength matches" do
      candidate_a = Struct.new(:prefix, :name).new("/media", "first")
      candidate_b = Struct.new(:prefix, :name).new("/media", "second")

      match = described_class.best_match(path: "/media/movies/test.mkv", candidates: [ candidate_a, candidate_b ], &:prefix)

      expect(match).to eq(candidate_a)
    end
  end
end
