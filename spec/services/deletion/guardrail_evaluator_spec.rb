require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Deletion::GuardrailEvaluator, type: :service do
  def create_radarr_integration!(name:, host:)
    Integration.create!(
      kind: "radarr",
      name: name,
      base_url: "https://#{host}.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  def create_sonarr_integration!(name:, host:)
    Integration.create!(
      kind: "sonarr",
      name: name,
      base_url: "https://#{host}.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  it "returns path_excluded when canonical path falls under an enabled exclusion prefix" do
    integration = create_radarr_integration!(name: "Radarr Exclusion", host: "radarr-exclusion")
    movie = Movie.create!(integration:, radarr_movie_id: 101, title: "Excluded Movie", duration_ms: 100_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 201,
      path: "/media/excluded/movie.mkv",
      path_canonical: "/media/excluded/movie.mkv",
      size_bytes: 1.gigabyte
    )
    PathExclusion.create!(name: "Excluded Prefix", path_prefix: "/media/excluded")

    result = described_class.new(selected_plex_user_ids: []).call(media_file: media_file)

    expect(result.blocker_flags).to include("path_excluded")
    expect(result.error_codes).to include("guardrail_path_excluded")
  end

  it "returns keep_marked for episode files when keep marker is on the parent series" do
    integration = create_sonarr_integration!(name: "Sonarr Keep", host: "sonarr-keep")
    series = Series.create!(integration:, sonarr_series_id: 301, title: "Keep Series")
    season = Season.create!(series:, season_number: 1)
    episode = Episode.create!(
      season: season,
      integration: integration,
      sonarr_episode_id: 401,
      episode_number: 1,
      duration_ms: 100_000
    )
    media_file = MediaFile.create!(
      attachable: episode,
      integration: integration,
      arr_file_id: 501,
      path: "/media/tv/keep-series-s01e01.mkv",
      path_canonical: "/media/tv/keep-series-s01e01.mkv",
      size_bytes: 1.gigabyte
    )
    KeepMarker.create!(keepable: series)

    result = described_class.new(selected_plex_user_ids: []).call(media_file: media_file)

    expect(result.blocker_flags).to include("keep_marked")
    expect(result.error_codes).to include("guardrail_keep_marker")
  end

  it "returns in_progress_any when any selected user is still in progress" do
    integration = create_radarr_integration!(name: "Radarr Progress", host: "radarr-progress")
    movie = Movie.create!(integration:, radarr_movie_id: 601, title: "In Progress Movie", duration_ms: 200_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 701,
      path: "/media/movies/in-progress.mkv",
      path_canonical: "/media/movies/in-progress.mkv",
      size_bytes: 1.gigabyte
    )
    user = PlexUser.create!(tautulli_user_id: 801, friendly_name: "Progress User", is_hidden: false)
    WatchStat.create!(
      plex_user: user,
      watchable: movie,
      play_count: 0,
      in_progress: true,
      max_view_offset_ms: 20_000
    )

    result = described_class.new(selected_plex_user_ids: [ user.id ]).call(media_file: media_file)

    expect(result.blocker_flags).to include("in_progress_any")
    expect(result.error_codes).to include("guardrail_in_progress")
  end

  it "returns ambiguous_mapping when attachable metadata flags ambiguity" do
    integration = create_radarr_integration!(name: "Radarr Ambiguous", host: "radarr-ambiguous")
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 901,
      title: "Ambiguous Mapping Movie",
      duration_ms: 200_000,
      metadata_json: { "ambiguous_mapping" => true }
    )
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 902,
      path: "/media/movies/ambiguous-mapping.mkv",
      path_canonical: "/media/movies/ambiguous-mapping.mkv",
      size_bytes: 1.gigabyte
    )

    result = described_class.new(selected_plex_user_ids: []).call(media_file: media_file)

    expect(result.blocker_flags).to include("ambiguous_mapping")
    expect(result.error_codes).to include("guardrail_ambiguous_mapping")
  end

  it "returns ambiguous_ownership when the same canonical path is owned by multiple integrations" do
    first_integration = create_radarr_integration!(name: "Radarr Primary", host: "radarr-primary")
    second_integration = create_radarr_integration!(name: "Radarr Secondary", host: "radarr-secondary")
    first_movie = Movie.create!(integration: first_integration, radarr_movie_id: 1001, title: "Owner A", duration_ms: 100_000)
    second_movie = Movie.create!(integration: second_integration, radarr_movie_id: 1002, title: "Owner B", duration_ms: 100_000)
    path = "/media/movies/overlap-file.mkv"
    media_file = MediaFile.create!(
      attachable: first_movie,
      integration: first_integration,
      arr_file_id: 1101,
      path: path,
      path_canonical: path,
      size_bytes: 1.gigabyte
    )
    MediaFile.create!(
      attachable: second_movie,
      integration: second_integration,
      arr_file_id: 1102,
      path: path,
      path_canonical: path,
      size_bytes: 1.gigabyte
    )

    result = described_class.new(selected_plex_user_ids: []).call(media_file: media_file)

    expect(result.blocker_flags).to include("ambiguous_ownership")
    expect(result.error_codes).to include("guardrail_ambiguous_ownership")
  end
end
# rubocop:enable RSpec/ExampleLength
