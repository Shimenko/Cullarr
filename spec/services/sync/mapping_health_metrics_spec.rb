require "rails_helper"

RSpec.describe Sync::MappingHealthMetrics, type: :service do
  let!(:sonarr) do
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Metrics Service",
      base_url: "https://sonarr.metrics.service.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  let!(:radarr) do
    Integration.create!(
      kind: "radarr",
      name: "Radarr Metrics Service",
      base_url: "https://radarr.metrics.service.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  before do
    create_mapping_fixture_records!
  end

  it "returns aggregate mapping health metrics" do
    metrics = described_class.new.call

    expect(metrics).to include(
      enabled_path_mappings: 1,
      media_files_total: 2,
      media_files_with_canonical_path: 2,
      ambiguous_path_count: 1,
      ambiguous_media_file_count: 2,
      integrations_without_path_mappings: 1
    )
  end

  def create_mapping_fixture_records!
    PathMapping.create!(integration: sonarr, from_prefix: "/data", to_prefix: "/mnt")

    movie = Movie.create!(integration: radarr, radarr_movie_id: 5, title: "Movie A")
    episode_series = Series.create!(integration: sonarr, sonarr_series_id: 77, title: "Series A")
    season = Season.create!(series: episode_series, season_number: 1)
    episode = Episode.create!(integration: sonarr, season:, sonarr_episode_id: 7001, episode_number: 1)

    create_media_file!(attachable: movie, integration: radarr, arr_file_id: 100, path: "/data/movies/a.mkv")
    create_media_file!(attachable: episode, integration: sonarr, arr_file_id: 101, path: "/data/tv/a.mkv")
  end

  def create_media_file!(attachable:, integration:, arr_file_id:, path:)
    MediaFile.create!(
      attachable:,
      integration:,
      arr_file_id:,
      path:,
      path_canonical: "/mnt/shared/a.mkv",
      size_bytes: 1
    )
  end
end
