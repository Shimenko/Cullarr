require "rails_helper"

RSpec.describe Movie, type: :model do
  def create_integration!
    Integration.create!(
      kind: "radarr",
      name: "Radarr Movie Model",
      base_url: "https://radarr.movie-model.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  def create_movie!(integration:, radarr_movie_id:, title:, attrs: {})
    described_class.create!(
      {
        integration: integration,
        radarr_movie_id: radarr_movie_id,
        title: title
      }.merge(attrs)
    )
  end

  it "defaults mapping columns to unresolved state" do
    movie = described_class.create!(
      integration: create_integration!,
      radarr_movie_id: 9001,
      title: "Mapping Defaults Movie"
    )

    expect(movie.mapping_status_code).to eq("unresolved")
    expect(movie.mapping_strategy).to eq("no_match")
    expect(movie.mapping_diagnostics_json).to eq({})
    expect(movie.mapping_status_changed_at).to be_nil
  end

  it "validates mapping status code inclusion" do
    movie = described_class.new(
      integration: create_integration!,
      radarr_movie_id: 9002,
      title: "Invalid Status Movie",
      mapping_status_code: "not_a_real_status"
    )

    expect(movie).not_to be_valid
    expect(movie.errors[:mapping_status_code]).to include("is not included in the list")
  end

  it "validates mapping strategy inclusion" do
    movie = described_class.new(
      integration: create_integration!,
      radarr_movie_id: 9003,
      title: "Invalid Strategy Movie",
      mapping_strategy: "not_a_real_strategy"
    )

    expect(movie).not_to be_valid
    expect(movie.errors[:mapping_strategy]).to include("is not included in the list")
  end

  it "validates mapping diagnostics object type" do
    movie = described_class.new(
      integration: create_integration!,
      radarr_movie_id: 9004,
      title: "Invalid Diagnostics Movie",
      mapping_diagnostics_json: []
    )

    expect(movie).not_to be_valid
    expect(movie.errors[:mapping_diagnostics_json]).to include("must be an object")
  end

  it "updates mapping_status_changed_at only when status changes" do
    movie = create_movie!(integration: create_integration!, radarr_movie_id: 9005, title: "Timestamp Movie")
    expect(movie.mapping_status_changed_at).to be_nil

    movie.apply_mapping_state!(status_code: "verified_path", strategy: "path_match", diagnostics: { source: "path" })
    first_changed_at = movie.reload.mapping_status_changed_at
    expect(first_changed_at).to be_present

    movie.apply_mapping_state!(status_code: "verified_path", strategy: "external_ids_match", diagnostics: { source: "ids" })
    expect(movie.reload.mapping_status_changed_at).to eq(first_changed_at)
  end

  it "enforces status constraint at database level" do
    movie = described_class.create!(
      integration: create_integration!,
      radarr_movie_id: 9006,
      title: "DB Constraint Movie"
    )

    expect do
      movie.update_columns(mapping_status_code: "invalid_status")
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
