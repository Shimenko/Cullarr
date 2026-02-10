require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Api::V1::Candidates", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  describe "GET /api/v1/candidates" do
    it "requires authentication" do
      get "/api/v1/candidates", params: { scope: "movie" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "validates unsupported scopes" do
      sign_in_operator!

      get "/api/v1/candidates", params: { scope: "tv_scope_unknown" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
      expect(response.parsed_body.dig("error", "details", "fields", "scope")).to eq(
        [ "must be one of: movie, tv_episode, tv_season, tv_show" ]
      )
    end

    it "requires scope when neither scope nor saved_view_id scope is provided" do
      sign_in_operator!

      get "/api/v1/candidates", as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
      expect(response.parsed_body.dig("error", "details", "fields", "scope")).to eq([ "is required" ])
    end

    it "returns movie candidates with contract-shaped metadata" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Main",
        base_url: "https://radarr.candidates.local",
        api_key: "secret",
        verify_ssl: true
      )
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 101,
        title: "Movie Candidate",
        year: 2020,
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 301,
        path: "/media/movies/movie-candidate-1080p.mkv",
        path_canonical: "/media/movies/movie-candidate-1080p.mkv",
        size_bytes: 5.gigabytes
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 302,
        path: "/media/movies/movie-candidate-4k.mkv",
        path_canonical: "/media/movies/movie-candidate-4k.mkv",
        size_bytes: 10.gigabytes
      )

      user_one = PlexUser.create!(tautulli_user_id: 1, friendly_name: "Alice", is_hidden: false)
      user_two = PlexUser.create!(tautulli_user_id: 2, friendly_name: "Bob", is_hidden: false)

      WatchStat.create!(
        plex_user: user_one,
        watchable: movie,
        play_count: 1,
        last_watched_at: 30.days.ago
      )
      WatchStat.create!(
        plex_user: user_two,
        watchable: movie,
        play_count: 2,
        last_watched_at: 10.days.ago
      )

      get "/api/v1/candidates", params: { scope: "movie", plex_user_ids: [ user_one.id, user_two.id ] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")

      payload = response.parsed_body
      expect(payload.fetch("scope")).to eq("movie")
      expect(payload.dig("filters", "plex_user_ids")).to contain_exactly(user_one.id, user_two.id)
      expect(payload.dig("filters", "include_blocked")).to be(false)

      row = payload.fetch("items").first
      expect(row.fetch("id")).to eq("movie:#{movie.id}")
      expect(row.fetch("candidate_id")).to eq("movie:#{movie.id}")
      expect(row.fetch("version_count")).to eq(2)
      expect(row.fetch("risk_flags")).to include("multiple_versions")
      expect(row.fetch("blocker_flags")).to eq([])
      expect(row.dig("watched_summary", "all_selected_users_watched")).to be(true)
      expect(row.fetch("reasons")).to include("watched_by_all_selected_users")
    end

    it "returns tv_episode candidates with contract fields" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.candidates.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 501, title: "Series Candidate")
      season = Season.create!(series: series, season_number: 1)
      episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 601,
        episode_number: 2,
        title: "Episode Candidate",
        duration_ms: 200_000
      )
      MediaFile.create!(
        attachable: episode,
        integration: integration,
        arr_file_id: 701,
        path: "/media/tv/series-candidate-s01e02.mkv",
        path_canonical: "/media/tv/series-candidate-s01e02.mkv",
        size_bytes: 4.gigabytes
      )
      user = PlexUser.create!(tautulli_user_id: 61, friendly_name: "TV User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: episode, play_count: 1, last_watched_at: 2.days.ago)

      get "/api/v1/candidates", params: { scope: "tv_episode", plex_user_ids: [ user.id ] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("scope")).to eq("tv_episode")
      row = response.parsed_body.fetch("items").first
      expect(row.fetch("id")).to eq("episode:#{episode.id}")
      expect(row.fetch("scope")).to eq("tv_episode")
      expect(row.fetch("episode_id")).to eq(episode.id)
      expect(row.fetch("series_id")).to eq(series.id)
      expect(row.fetch("season_number")).to eq(1)
      expect(row.fetch("episode_number")).to eq(2)
      expect(row.fetch("media_file_ids")).to eq([ episode.media_files.first.id ])
    end

    it "returns tv_season rollups with strict eligibility blocker metadata" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Season",
        base_url: "https://sonarr.season.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 801, title: "Season Rollup")
      season = Season.create!(series: series, season_number: 2)
      eligible_episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 901,
        episode_number: 1,
        duration_ms: 100_000
      )
      blocked_episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 902,
        episode_number: 2,
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: eligible_episode,
        integration: integration,
        arr_file_id: 1001,
        path: "/media/tv/season-rollup-s02e01.mkv",
        path_canonical: "/media/tv/season-rollup-s02e01.mkv",
        size_bytes: 1.gigabyte
      )
      MediaFile.create!(
        attachable: blocked_episode,
        integration: integration,
        arr_file_id: 1002,
        path: "/media/tv/season-rollup-s02e02.mkv",
        path_canonical: "/media/tv/season-rollup-s02e02.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 62, friendly_name: "Season User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: eligible_episode, play_count: 1)
      WatchStat.create!(
        plex_user: user,
        watchable: blocked_episode,
        play_count: 1,
        in_progress: true,
        max_view_offset_ms: 5_000
      )

      get "/api/v1/candidates", params: { scope: "tv_season", include_blocked: true, plex_user_ids: [ user.id ] }, as: :json

      expect(response).to have_http_status(:ok)
      row = response.parsed_body.fetch("items").first
      expect(row.fetch("scope")).to eq("tv_season")
      expect(row.fetch("season_id")).to eq(season.id)
      expect(row.fetch("episode_count")).to eq(2)
      expect(row.fetch("eligible_episode_count")).to eq(1)
      expect(row.fetch("blocker_flags")).to include("in_progress_any", "rollup_not_strictly_eligible")
    end

    it "returns tv_show rollups with strict eligibility blocker metadata" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Show",
        base_url: "https://sonarr.show.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 1801, title: "Show Rollup")
      season = Season.create!(series: series, season_number: 1)
      episode_one = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 1901,
        episode_number: 1,
        duration_ms: 100_000
      )
      episode_two = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 1902,
        episode_number: 2,
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: episode_one,
        integration: integration,
        arr_file_id: 2001,
        path: "/media/tv/show-rollup-s01e01.mkv",
        path_canonical: "/media/tv/show-rollup-s01e01.mkv",
        size_bytes: 1.gigabyte
      )
      MediaFile.create!(
        attachable: episode_two,
        integration: integration,
        arr_file_id: 2002,
        path: "/media/tv/show-rollup-s01e02.mkv",
        path_canonical: "/media/tv/show-rollup-s01e02.mkv",
        size_bytes: 1.gigabyte
      )
      KeepMarker.create!(keepable: episode_two, note: "Keep this episode")
      user = PlexUser.create!(tautulli_user_id: 63, friendly_name: "Show User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: episode_one, play_count: 1)
      WatchStat.create!(plex_user: user, watchable: episode_two, play_count: 1)

      get "/api/v1/candidates", params: { scope: "tv_show", include_blocked: true, plex_user_ids: [ user.id ] }, as: :json

      expect(response).to have_http_status(:ok)
      row = response.parsed_body.fetch("items").first
      expect(row.fetch("scope")).to eq("tv_show")
      expect(row.fetch("series_id")).to eq(series.id)
      expect(row.fetch("episode_count")).to eq(2)
      expect(row.fetch("eligible_episode_count")).to eq(1)
      expect(row.fetch("blocker_flags")).to include("keep_marked", "rollup_not_strictly_eligible")
    end

    it "hides blocked rows by default and returns them when include_blocked=true" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Blocked",
        base_url: "https://radarr.blocked.local",
        api_key: "secret",
        verify_ssl: true
      )
      movie = Movie.create!(integration: integration, radarr_movie_id: 201, title: "Blocked Movie", duration_ms: 100_000)
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 401,
        path: "/media/movies/blocked.mkv",
        path_canonical: "/media/movies/blocked.mkv",
        size_bytes: 2.gigabytes
      )
      user = PlexUser.create!(tautulli_user_id: 21, friendly_name: "Eve", is_hidden: false)
      WatchStat.create!(
        plex_user: user,
        watchable: movie,
        play_count: 1,
        in_progress: true,
        max_view_offset_ms: 20_000
      )

      get "/api/v1/candidates", params: { scope: "movie", plex_user_ids: [ user.id ] }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("items")).to eq([])

      get "/api/v1/candidates", params: { scope: "movie", include_blocked: true, plex_user_ids: [ user.id ] }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("items").first.fetch("blocker_flags")).to include("in_progress_any")
    end

    it "emits guardrail blocked events when rows are filtered by guardrails" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Guardrail Event",
        base_url: "https://radarr.guardrail-event.local",
        api_key: "secret",
        verify_ssl: true
      )
      PathExclusion.create!(name: "Excluded", path_prefix: "/media/excluded")
      movie = Movie.create!(integration: integration, radarr_movie_id: 203, title: "Guardrail Event Movie")
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 403,
        path: "/media/excluded/guardrail-event.mkv",
        path_canonical: "/media/excluded/guardrail-event.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 22, friendly_name: "Guardrail User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)

      expect do
        get "/api/v1/candidates", params: { scope: "movie", plex_user_ids: [ user.id ] }, as: :json
      end.to change { AuditEvent.where(event_name: "cullarr.guardrail.blocked_path_excluded").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("items")).to eq([])
      payload = AuditEvent.where(event_name: "cullarr.guardrail.blocked_path_excluded").order(:id).last.payload_json
      expect(payload).to include("scope" => "movie", "blocked_count" => 1, "include_blocked" => false)
    end

    it "supports selected plex user filtering" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Users",
        base_url: "https://radarr.users.local",
        api_key: "secret",
        verify_ssl: true
      )
      movie = Movie.create!(integration: integration, radarr_movie_id: 202, title: "User Filter Movie")
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 402,
        path: "/media/movies/users.mkv",
        path_canonical: "/media/movies/users.mkv",
        size_bytes: 3.gigabytes
      )
      watched_user = PlexUser.create!(tautulli_user_id: 31, friendly_name: "Watched User", is_hidden: false)
      unwatched_user = PlexUser.create!(tautulli_user_id: 32, friendly_name: "Unwatched User", is_hidden: false)
      WatchStat.create!(plex_user: watched_user, watchable: movie, play_count: 1)
      WatchStat.create!(plex_user: unwatched_user, watchable: movie, play_count: 0)

      get "/api/v1/candidates", params: { scope: "movie" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("items")).to eq([])

      get "/api/v1/candidates", params: { scope: "movie", plex_user_ids: [ watched_user.id ] }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("items").size).to eq(1)
      expect(response.parsed_body.dig("filters", "plex_user_ids")).to eq([ watched_user.id ])
    end

    it "supports cursor pagination with next_cursor metadata" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Cursor",
        base_url: "https://radarr.cursor.local",
        api_key: "secret",
        verify_ssl: true
      )
      user = PlexUser.create!(tautulli_user_id: 71, friendly_name: "Cursor User", is_hidden: false)
      first_movie = Movie.create!(integration: integration, radarr_movie_id: 301, title: "Cursor Movie 1")
      second_movie = Movie.create!(integration: integration, radarr_movie_id: 302, title: "Cursor Movie 2")

      [ first_movie, second_movie ].each_with_index do |movie, idx|
        MediaFile.create!(
          attachable: movie,
          integration: integration,
          arr_file_id: 3001 + idx,
          path: "/media/movies/cursor-#{movie.id}.mkv",
          path_canonical: "/media/movies/cursor-#{movie.id}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)
      end

      get "/api/v1/candidates", params: { scope: "movie", limit: 1, plex_user_ids: [ user.id ] }, as: :json
      expect(response).to have_http_status(:ok)
      first_page = response.parsed_body
      expect(first_page.fetch("items").size).to eq(1)
      expect(first_page.dig("page", "next_cursor")).to be_present

      get "/api/v1/candidates", params: { scope: "movie", limit: 1, cursor: first_page.dig("page", "next_cursor"), plex_user_ids: [ user.id ] }, as: :json
      expect(response).to have_http_status(:ok)
      second_page = response.parsed_body
      expect(second_page.fetch("items").size).to eq(1)
      expect(second_page.fetch("items").first.fetch("id")).not_to eq(first_page.fetch("items").first.fetch("id"))
    end

    it "validates cursor format" do
      sign_in_operator!

      get "/api/v1/candidates", params: { scope: "movie", cursor: "invalid" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "cursor")).to eq([ "must be a positive integer" ])
    end

    it "validates limit format" do
      sign_in_operator!

      get "/api/v1/candidates", params: { scope: "movie", limit: 0 }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "limit")).to eq([ "must be a positive integer" ])
    end

    it "validates plex_user_ids format" do
      sign_in_operator!

      get "/api/v1/candidates", params: { scope: "movie", plex_user_ids: [ "abc" ] }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "plex_user_ids")).to eq([ "must contain positive integers" ])
    end

    it "validates include_blocked format" do
      sign_in_operator!

      get "/api/v1/candidates", params: { scope: "movie", include_blocked: "definitely_not_boolean" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "include_blocked")).to eq([ "must be true or false" ])
    end

    it "uses saved view scope and filters when query params are omitted" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Preset",
        base_url: "https://sonarr.preset.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 4001, title: "Preset Series")
      season = Season.create!(series: series, season_number: 1)
      episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 4002,
        episode_number: 3,
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: episode,
        integration: integration,
        arr_file_id: 4003,
        path: "/media/tv/preset-series-s01e03.mkv",
        path_canonical: "/media/tv/preset-series-s01e03.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 81, friendly_name: "Preset User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)

      saved_view = SavedView.create!(
        name: "Episode Preset",
        scope: "tv_episode",
        filters_json: {
          "plex_user_ids" => [ user.id ],
          "include_blocked" => false
        }
      )

      get "/api/v1/candidates", params: { saved_view_id: saved_view.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("scope")).to eq("tv_episode")
      expect(response.parsed_body.dig("filters", "saved_view_id")).to eq(saved_view.id)
      expect(response.parsed_body.dig("filters", "plex_user_ids")).to eq([ user.id ])
      expect(response.parsed_body.fetch("items").size).to eq(1)
      expect(response.parsed_body.fetch("items").first.fetch("id")).to eq("episode:#{episode.id}")
    end

    it "allows explicit query params to override saved view filters" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Preset Override",
        base_url: "https://radarr.preset-override.local",
        api_key: "secret",
        verify_ssl: true
      )
      movie = Movie.create!(integration: integration, radarr_movie_id: 5001, title: "Preset Override Movie")
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 5002,
        path: "/media/movies/preset-override.mkv",
        path_canonical: "/media/movies/preset-override.mkv",
        size_bytes: 1.gigabyte
      )
      watched_user = PlexUser.create!(tautulli_user_id: 82, friendly_name: "Watched Override", is_hidden: false)
      unwatched_user = PlexUser.create!(tautulli_user_id: 83, friendly_name: "Unwatched Override", is_hidden: false)
      WatchStat.create!(plex_user: watched_user, watchable: movie, play_count: 1)
      WatchStat.create!(plex_user: unwatched_user, watchable: movie, play_count: 0)

      saved_view = SavedView.create!(
        name: "Movie Preset",
        scope: "movie",
        filters_json: { "plex_user_ids" => [ unwatched_user.id ] }
      )

      get "/api/v1/candidates", params: { saved_view_id: saved_view.id, plex_user_ids: [ watched_user.id ] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("items").size).to eq(1)
      expect(response.parsed_body.dig("filters", "plex_user_ids")).to eq([ watched_user.id ])
    end

    it "validates mismatched explicit scope and saved view scope" do
      sign_in_operator!
      saved_view = SavedView.create!(name: "Scope Preset", scope: "tv_show", filters_json: {})

      get "/api/v1/candidates", params: { saved_view_id: saved_view.id, scope: "movie" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
      expect(response.parsed_body.dig("error", "details", "fields", "scope")).to eq([ "must match saved view scope tv_show" ])
    end

    it "returns not_found when saved_view_id does not exist" do
      sign_in_operator!

      get "/api/v1/candidates", params: { saved_view_id: 999999 }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_found")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
      expect(response.parsed_body.dig("error", "details", "saved_view_id")).to eq(999999)
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
