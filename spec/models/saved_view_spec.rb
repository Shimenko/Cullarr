require "rails_helper"

RSpec.describe SavedView, type: :model do
  it "validates scope inclusion" do
    saved_view = described_class.new(name: "Invalid Scope", scope: "unknown", filters_json: {})

    expect(saved_view).not_to be_valid
    expect(saved_view.errors[:scope]).to include("is not included in the list")
  end

  it "normalizes name whitespace" do
    saved_view = described_class.create!(name: "  My View  ", scope: "movie", filters_json: {})

    expect(saved_view.name).to eq("My View")
  end

  it "rejects unsupported filter keys" do
    saved_view = described_class.new(
      name: "Unsupported Filters",
      scope: "movie",
      filters_json: { "unknown_filter" => true }
    )

    expect(saved_view).not_to be_valid
    expect(saved_view.errors[:filters_json]).to include("contains unsupported keys: unknown_filter")
  end

  it "rejects non-object filters_json payloads" do
    saved_view = described_class.new(
      name: "Bad Filter Type",
      scope: "movie",
      filters_json: [ 1, 2, 3 ]
    )

    expect(saved_view).not_to be_valid
    expect(saved_view.errors[:filters_json]).to include("must be an object")
  end

  it "rejects non-array or non-integer plex_user_ids values" do
    saved_view = described_class.new(
      name: "Bad Plex User Filters",
      scope: "movie",
      filters_json: { "plex_user_ids" => [ 1, "2", 0 ] }
    )

    expect(saved_view).not_to be_valid
    expect(saved_view.errors.attribute_names).to include(:"filters.plex_user_ids")
  end

  it "rejects non-boolean include_blocked values" do
    saved_view = described_class.new(
      name: "Bad Include Blocked",
      scope: "movie",
      filters_json: { "include_blocked" => "true" }
    )

    expect(saved_view).not_to be_valid
    expect(saved_view.errors.attribute_names).to include(:"filters.include_blocked")
  end
end
