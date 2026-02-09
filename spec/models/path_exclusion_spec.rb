require "rails_helper"

RSpec.describe PathExclusion, type: :model do
  it "normalizes path prefix" do
    exclusion = described_class.create!(name: "Kids", path_prefix: "/media//kids/")

    expect(exclusion.path_prefix).to eq("/media/kids")
  end

  it "deduplicates normalized path prefixes" do
    described_class.create!(name: "Kids", path_prefix: "/media/kids")
    duplicate = described_class.new(name: "Kids 2", path_prefix: "/media//kids/")

    expect(duplicate).not_to be_valid
  end
end
