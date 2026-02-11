require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Candidates::Query, type: :service do
  it "keeps guardrail event names aligned with the event schema catalog" do
    expect(described_class::GUARDRAIL_EVENT_BY_FLAG).to eq(
      "path_excluded" => "cullarr.guardrail.blocked_path_excluded",
      "keep_marked" => "cullarr.guardrail.blocked_keep_marker",
      "in_progress_any" => "cullarr.guardrail.blocked_in_progress",
      "ambiguous_mapping" => "cullarr.guardrail.blocked_ambiguous_mapping",
      "ambiguous_ownership" => "cullarr.guardrail.blocked_ambiguous_ownership"
    )
  end

  describe "#call" do
    it "requires scope when request scope and saved view scope are both absent" do
      expect do
        described_class.new(
          scope: nil,
          saved_view_id: nil,
          plex_user_ids: nil,
          include_blocked: false,
          cursor: nil,
          limit: nil
        ).call
      end.to raise_error(described_class::InvalidFilterError) { |error|
        expect(error.fields).to eq({ "scope" => [ "is required" ] })
      }
    end

    it "uses saved view scope when explicit scope is omitted" do
      integration = create_integration!(name: "Radarr Saved Scope", host: "saved-scope")
      user = PlexUser.create!(tautulli_user_id: 105, friendly_name: "Saved Scope User", is_hidden: false)
      movie = Movie.create!(integration: integration, radarr_movie_id: 12, title: "Saved Scope Movie", duration_ms: 100_000)
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 12,
        path: "/media/movies/saved-scope.mkv",
        path_canonical: "/media/movies/saved-scope.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)
      saved_view = SavedView.create!(name: "Movie Scope Preset", scope: "movie", filters_json: { "plex_user_ids" => [ user.id ] })

      result = described_class.new(
        scope: nil,
        saved_view_id: saved_view.id,
        plex_user_ids: nil,
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      expect(result.scope).to eq("movie")
      expect(result.filters[:saved_view_id]).to eq(saved_view.id)
      expect(result.items.size).to eq(1)
    end

    it "rejects invalid include_blocked values" do
      expect do
        described_class.new(
          scope: "movie",
          saved_view_id: nil,
          plex_user_ids: nil,
          include_blocked: "not_boolean",
          cursor: nil,
          limit: nil
        ).call
      end.to raise_error(described_class::InvalidFilterError) { |error|
        expect(error.fields).to eq({ "include_blocked" => [ "must be true or false" ] })
      }
    end

    it "rejects invalid watched_match_mode values" do
      expect do
        described_class.new(
          scope: "movie",
          saved_view_id: nil,
          plex_user_ids: nil,
          include_blocked: false,
          watched_match_mode: "sometimes",
          cursor: nil,
          limit: nil
        ).call
      end.to raise_error(described_class::InvalidFilterError) { |error|
        expect(error.fields).to eq({ "watched_match_mode" => [ "must be one of: all, any, none" ] })
      }
    end

    it "supports watched_match_mode=any and returns diagnostics for strict filtering" do
      integration = create_integration!(name: "Radarr Match Mode", host: "match-mode")
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 333,
        title: "Match Mode Movie",
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 334,
        path: "/media/movies/match-mode.mkv",
        path_canonical: "/media/movies/match-mode.mkv",
        size_bytes: 1.gigabyte
      )
      watched_user = PlexUser.create!(tautulli_user_id: 2233, friendly_name: "Watched", is_hidden: false)
      unwatched_user = PlexUser.create!(tautulli_user_id: 2234, friendly_name: "Unwatched", is_hidden: false)
      WatchStat.create!(plex_user: watched_user, watchable: movie, play_count: 1)
      WatchStat.create!(plex_user: unwatched_user, watchable: movie, play_count: 0)

      strict_result = described_class.new(
        scope: "movie",
        plex_user_ids: [ watched_user.id, unwatched_user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call
      any_result = described_class.new(
        scope: "movie",
        plex_user_ids: [ watched_user.id, unwatched_user.id ],
        include_blocked: false,
        watched_match_mode: "any",
        cursor: nil,
        limit: nil
      ).call

      expect(strict_result.items).to eq([])
      expect(strict_result.diagnostics).to include(
        watched_match_mode: "all",
        watched_prefilter_applied: true,
        rows_scanned: 0,
        rows_filtered_unwatched: 0,
        rows_returned: 0
      )
      expect(any_result.filters).to include(watched_match_mode: "any")
      expect(any_result.items.map { |row| row[:candidate_id] }).to contain_exactly("movie:#{movie.id}")
      expect(any_result.diagnostics).to include(
        watched_match_mode: "any",
        watched_prefilter_applied: true,
        rows_scanned: 1,
        rows_filtered_unwatched: 0,
        rows_returned: 1
      )
    end

    it "keeps default plex user selection empty while evaluating watched filters against all users" do
      integration = create_integration!(name: "Radarr Default Users", host: "default-users")
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 1_111,
        title: "Default User Filter Movie",
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 1_112,
        path: "/media/movies/default-users.mkv",
        path_canonical: "/media/movies/default-users.mkv",
        size_bytes: 1.gigabyte
      )
      watched_user = PlexUser.create!(tautulli_user_id: 711, friendly_name: "Default Watched", is_hidden: false)
      unwatched_user = PlexUser.create!(tautulli_user_id: 712, friendly_name: "Default Unwatched", is_hidden: false)
      WatchStat.create!(plex_user: watched_user, watchable: movie, play_count: 1)
      WatchStat.create!(plex_user: unwatched_user, watchable: movie, play_count: 0)

      result = described_class.new(
        scope: "movie",
        plex_user_ids: nil,
        include_blocked: false,
        watched_match_mode: "none",
        cursor: nil,
        limit: nil
      ).call

      expect(result.filters[:plex_user_ids]).to eq([])
      expect(result.filters[:watched_match_mode]).to eq("none")
      expect(result.diagnostics).to include(selected_user_count: 0, effective_selected_user_count: 2)
      expect(result.items).to eq([])
    end

    it "treats rollups with no eligible episode snapshots as unwatched for none mode" do
      user = PlexUser.create!(tautulli_user_id: 3001, friendly_name: "Rollup User", is_hidden: false)
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Rollup Empty",
        base_url: "https://sonarr.rollup-empty.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration:, sonarr_series_id: 31_001, title: "Rollup Empty Show")
      season = Season.create!(series:, season_number: 1)
      episode = Episode.create!(
        integration: integration,
        season: season,
        sonarr_episode_id: 31_101,
        episode_number: 1,
        duration_ms: 100_000
      )
      WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)

      result = described_class.new(
        scope: "tv_season",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "none",
        cursor: nil,
        limit: nil
      ).call

      expect(result.items.map { |row| row[:id] }).to contain_exactly("season:#{season.id}")
      expect(result.items.first.dig(:watched_summary, :watched_user_count)).to eq(0)
      expect(result.items.first.dig(:watched_summary, :all_selected_users_watched)).to be(false)
    end

    it "uses percent watched mode when duration is present" do
      AppSetting.create!(key: "watched_mode", value_json: "percent")
      AppSetting.create!(key: "watched_percent_threshold", value_json: 90)

      integration = create_integration!(name: "Radarr Percent", host: "percent")
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 10,
        title: "Percent Movie",
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 10,
        path: "/media/movies/percent.mkv",
        path_canonical: "/media/movies/percent.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 100, friendly_name: "Percent User", is_hidden: false)
      WatchStat.create!(
        plex_user: user,
        watchable: movie,
        play_count: 0,
        max_view_offset_ms: 95_000
      )

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      expect(result.items.size).to eq(1)
      expect(result.items.first.dig(:watched_summary, :all_selected_users_watched)).to be(true)
    end

    it "falls back to play_count mode when duration is missing in percent mode" do
      AppSetting.create!(key: "watched_mode", value_json: "percent")
      AppSetting.create!(key: "watched_percent_threshold", value_json: 95)

      integration = create_integration!(name: "Radarr Fallback", host: "fallback")
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 11,
        title: "Fallback Movie",
        duration_ms: nil
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 11,
        path: "/media/movies/fallback.mkv",
        path_canonical: "/media/movies/fallback.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 101, friendly_name: "Fallback User", is_hidden: false)
      WatchStat.create!(
        plex_user: user,
        watchable: movie,
        play_count: 1,
        max_view_offset_ms: 10_000
      )

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      expect(result.items.size).to eq(1)
      expect(result.items.first.dig(:watched_summary, :watched_user_count)).to eq(1)
    end

    it "prefilters movie candidates in SQL for play_count mode" do
      user = PlexUser.create!(tautulli_user_id: 1011, friendly_name: "SQL Prefilter User", is_hidden: false)
      integration = create_integration!(name: "Radarr SQL Prefilter", host: "sql-prefilter")

      40.times do |index|
        movie = Movie.create!(
          integration: integration,
          radarr_movie_id: 7000 + index,
          title: "Unwatched Movie #{index}",
          duration_ms: 100_000
        )
        MediaFile.create!(
          attachable: movie,
          integration: integration,
          arr_file_id: 8000 + index,
          path: "/media/movies/sql-prefilter-unwatched-#{index}.mkv",
          path_canonical: "/media/movies/sql-prefilter-unwatched-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: movie, play_count: 0)
      end

      12.times do |index|
        movie = Movie.create!(
          integration: integration,
          radarr_movie_id: 9000 + index,
          title: "Watched Movie #{index}",
          duration_ms: 100_000
        )
        MediaFile.create!(
          attachable: movie,
          integration: integration,
          arr_file_id: 10_000 + index,
          path: "/media/movies/sql-prefilter-watched-#{index}.mkv",
          path_canonical: "/media/movies/sql-prefilter-watched-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)
      end

      query = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: 10
      )
      allow(query).to receive(:build_movie_row).and_call_original

      sql_statements = capture_select_sql do
        result = query.call
        expect(result.items.size).to eq(10)
      end

      expect(sql_statements.join("\n")).to match(/COUNT\(DISTINCT .*plex_user_id\)/)
      expect(query).to have_received(:build_movie_row).at_most(15).times
    end

    it "prefilters episode candidates in SQL for play_count mode" do
      user = PlexUser.create!(tautulli_user_id: 1013, friendly_name: "Episode SQL User", is_hidden: false)
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Episode SQL Prefilter",
        base_url: "https://sonarr.episode-sql.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 12_001, title: "Episode SQL Series")
      season = Season.create!(series: series, season_number: 1)

      30.times do |index|
        episode = Episode.create!(
          season: season,
          integration: integration,
          sonarr_episode_id: 13_000 + index,
          episode_number: index + 1,
          duration_ms: 100_000
        )
        MediaFile.create!(
          attachable: episode,
          integration: integration,
          arr_file_id: 14_000 + index,
          path: "/media/tv/episode-sql-unwatched-#{index}.mkv",
          path_canonical: "/media/tv/episode-sql-unwatched-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: episode, play_count: 0)
      end

      8.times do |index|
        episode = Episode.create!(
          season: season,
          integration: integration,
          sonarr_episode_id: 15_000 + index,
          episode_number: 100 + index,
          duration_ms: 100_000
        )
        MediaFile.create!(
          attachable: episode,
          integration: integration,
          arr_file_id: 16_000 + index,
          path: "/media/tv/episode-sql-watched-#{index}.mkv",
          path_canonical: "/media/tv/episode-sql-watched-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)
      end

      query = described_class.new(
        scope: "tv_episode",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: 10
      )
      allow(query).to receive(:build_episode_row).and_call_original

      sql_statements = capture_select_sql do
        result = query.call
        expect(result.items.size).to eq(8)
      end

      expect(sql_statements.join("\n")).to match(/COUNT\(DISTINCT .*plex_user_id\)/)
      expect(query).to have_received(:build_episode_row).at_most(12).times
    end

    it "keeps percent-mode watched semantics by skipping play_count prefilter SQL" do
      AppSetting.create!(key: "watched_mode", value_json: "percent")
      AppSetting.create!(key: "watched_percent_threshold", value_json: 90)

      user = PlexUser.create!(tautulli_user_id: 1012, friendly_name: "Percent SQL User", is_hidden: false)
      integration = create_integration!(name: "Radarr Percent SQL", host: "percent-sql")
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 11_001,
        title: "Percent Watched Movie",
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 11_002,
        path: "/media/movies/percent-sql.mkv",
        path_canonical: "/media/movies/percent-sql.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(
        plex_user: user,
        watchable: movie,
        play_count: 0,
        max_view_offset_ms: 95_000
      )

      sql_statements = capture_select_sql do
        result = described_class.new(
          scope: "movie",
          plex_user_ids: [ user.id ],
          include_blocked: true,
          watched_match_mode: "all",
          cursor: nil,
          limit: 10
        ).call

        expect(result.items.map { |row| row[:candidate_id] }).to include("movie:#{movie.id}")
      end

      expect(sql_statements.join("\n")).not_to match(/COUNT\(DISTINCT .*plex_user_id\)/)
    end

    it "projects path exclusion and ambiguous ownership blocker flags" do
      integration_one = create_integration!(name: "Radarr One", host: "one")
      integration_two = create_integration!(name: "Radarr Two", host: "two")
      PathExclusion.create!(name: "Shared", path_prefix: "/media/shared")

      movie_one = Movie.create!(integration: integration_one, radarr_movie_id: 20, title: "Movie One")
      movie_two = Movie.create!(integration: integration_two, radarr_movie_id: 21, title: "Movie Two")

      MediaFile.create!(
        attachable: movie_one,
        integration: integration_one,
        arr_file_id: 20,
        path: "/media/shared/duplicate.mkv",
        path_canonical: "/media/shared/duplicate.mkv",
        size_bytes: 1.gigabyte
      )
      MediaFile.create!(
        attachable: movie_two,
        integration: integration_two,
        arr_file_id: 21,
        path: "/media/shared/duplicate.mkv",
        path_canonical: "/media/shared/duplicate.mkv",
        size_bytes: 1.gigabyte
      )

      user = PlexUser.create!(tautulli_user_id: 102, friendly_name: "Blocked User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: movie_one, play_count: 1)
      WatchStat.create!(plex_user: user, watchable: movie_two, play_count: 1)

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "movie:#{movie_one.id}" }

      expect(row).to be_present
      expect(row[:blocker_flags]).to include("path_excluded", "ambiguous_ownership")
    end

    it "classifies plain-language mapping statuses for movie candidates" do
      integration = create_integration!(name: "Radarr Mapping Status", host: "mapping-status")
      user = PlexUser.create!(tautulli_user_id: 107, friendly_name: "Mapping Status User", is_hidden: false)

      missing_ids_movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_001,
        title: "Missing IDs Movie",
        plex_rating_key: nil,
        imdb_id: nil,
        tmdb_id: nil
      )
      path_mismatch_movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_002,
        title: "Path Mismatch Movie",
        plex_rating_key: nil,
        imdb_id: "tt07002",
        tmdb_id: 7002
      )
      low_confidence_movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_003,
        title: "Low Confidence Movie",
        plex_rating_key: "plex-7003",
        metadata_json: { "low_confidence_mapping" => true }
      )

      [ missing_ids_movie, path_mismatch_movie, low_confidence_movie ].each_with_index do |movie, index|
        MediaFile.create!(
          attachable: movie,
          integration: integration,
          arr_file_id: 8_000 + index,
          path: "/media/movies/mapping-status-#{index}.mkv",
          path_canonical: "/media/movies/mapping-status-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)
      end

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      rows_by_title = result.items.index_by { |row| row[:title] }
      expect(rows_by_title.dig("Missing IDs Movie", :mapping_status, :code)).to eq("unmapped_plex_data_missing_identifiers")
      expect(rows_by_title.dig("Path Mismatch Movie", :mapping_status, :code)).to eq("unmapped_check_path_mapping_between_arr_and_plex")
      expect(rows_by_title.dig("Low Confidence Movie", :mapping_status, :code)).to eq("mapped_linked_by_external_ids")
    end

    it "prefers ARR-added timestamps over record created_at for added-day reasons" do
      integration = create_integration!(name: "Radarr Added Date Source", host: "added-date-source")
      user = PlexUser.create!(tautulli_user_id: 7017, friendly_name: "Added Date User", is_hidden: false)

      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_777,
        title: "Added Date Movie",
        duration_ms: 100_000,
        metadata_json: { "arr_added_at" => 10.days.ago.iso8601 }
      )
      movie.update_columns(created_at: Time.current, updated_at: Time.current)
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 7_778,
        path: "/media/movies/added-date-source.mkv",
        path_canonical: "/media/movies/added-date-source.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "movie:#{movie.id}" }
      added_reason = row[:reasons].find { |reason| reason.start_with?("added_days_ago:") }
      expect(row).to be_present
      expect(added_reason).to be_present
      expect(added_reason.split(":").last.to_i).to be >= 10
    end

    it "returns ARR-managed diagnostics and excludes non-radarr movie rows from movie scope" do
      managed_integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Managed",
        base_url: "https://radarr.managed.local",
        api_key: "secret",
        verify_ssl: true
      )
      unmanaged_integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Unmanaged Movie Source",
        base_url: "https://sonarr.unmanaged-movie.local",
        api_key: "secret",
        verify_ssl: true
      )
      user = PlexUser.create!(tautulli_user_id: 108, friendly_name: "ARR Scope User", is_hidden: false)

      managed_movie = Movie.create!(
        integration: managed_integration,
        radarr_movie_id: 9_001,
        title: "Managed Movie",
        duration_ms: 100_000
      )
      unmanaged_movie = Movie.create!(
        integration: unmanaged_integration,
        radarr_movie_id: 9_002,
        title: "Unmanaged Movie",
        duration_ms: 100_000
      )
      [ managed_movie, unmanaged_movie ].each_with_index do |movie, index|
        MediaFile.create!(
          attachable: movie,
          integration: movie.integration,
          arr_file_id: 9_100 + index,
          path: "/media/movies/arr-scope-#{index}.mkv",
          path_canonical: "/media/movies/arr-scope-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)
      end

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      expect(result.diagnostics[:content_scope]).to eq("arr_managed_only")
      expect(result.items.map { |row| row[:title] }).to contain_exactly("Managed Movie")
    end

    it "treats series-level keep markers as episode blockers" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Keep Marker",
        base_url: "https://sonarr.keep-marker.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 1001, title: "Keeped Series")
      season = Season.create!(series: series, season_number: 3)
      episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 1002,
        episode_number: 7,
        title: "Blocked Episode",
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: episode,
        integration: integration,
        arr_file_id: 1003,
        path: "/media/tv/keeped-series-s03e07.mkv",
        path_canonical: "/media/tv/keeped-series-s03e07.mkv",
        size_bytes: 1.gigabyte
      )
      KeepMarker.create!(keepable: series, note: "Never delete this show")
      user = PlexUser.create!(tautulli_user_id: 103, friendly_name: "Keep Marker User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)

      result = described_class.new(
        scope: "tv_episode",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "episode:#{episode.id}" }

      expect(row).to be_present
      expect(row[:blocker_flags]).to include("keep_marked")
    end

    it "adds rollup_not_strictly_eligible for season rollups with blocked episodes" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Rollup",
        base_url: "https://sonarr.rollup.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 2001, title: "Rollup Series")
      season = Season.create!(series: series, season_number: 4)
      eligible_episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 2002,
        episode_number: 1,
        duration_ms: 100_000
      )
      blocked_episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 2003,
        episode_number: 2,
        duration_ms: 100_000
      )
      MediaFile.create!(
        attachable: eligible_episode,
        integration: integration,
        arr_file_id: 2004,
        path: "/media/tv/rollup-series-s04e01.mkv",
        path_canonical: "/media/tv/rollup-series-s04e01.mkv",
        size_bytes: 1.gigabyte
      )
      MediaFile.create!(
        attachable: blocked_episode,
        integration: integration,
        arr_file_id: 2005,
        path: "/media/tv/rollup-series-s04e02.mkv",
        path_canonical: "/media/tv/rollup-series-s04e02.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 104, friendly_name: "Rollup User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: eligible_episode, play_count: 1)
      WatchStat.create!(plex_user: user, watchable: blocked_episode, play_count: 1, in_progress: true, max_view_offset_ms: 2_000)

      result = described_class.new(
        scope: "tv_season",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "season:#{season.id}" }

      expect(row).to be_present
      expect(row[:episode_count]).to eq(2)
      expect(row[:eligible_episode_count]).to eq(1)
      expect(row[:blocker_flags]).to include("in_progress_any", "rollup_not_strictly_eligible")
    end

    it "avoids per-season integration queries when building season candidates" do
      user = PlexUser.create!(tautulli_user_id: 106, friendly_name: "Season Perf User", is_hidden: false)

      3.times do |index|
        integration = Integration.create!(
          kind: "sonarr",
          name: "Sonarr Season Perf #{index}",
          base_url: "https://sonarr.season-perf-#{index}.local",
          api_key: "secret",
          verify_ssl: true
        )
        series = Series.create!(integration: integration, sonarr_series_id: 3000 + index, title: "Series #{index}")
        season = Season.create!(series: series, season_number: 1)
        episode = Episode.create!(
          season: season,
          integration: integration,
          sonarr_episode_id: 4000 + index,
          episode_number: 1,
          duration_ms: 100_000
        )
        MediaFile.create!(
          attachable: episode,
          integration: integration,
          arr_file_id: 5000 + index,
          path: "/media/tv/season-perf-#{index}.mkv",
          path_canonical: "/media/tv/season-perf-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)
      end

      integration_select_count = count_select_queries_for("integrations") do
        described_class.new(
          scope: "tv_season",
          plex_user_ids: [ user.id ],
          include_blocked: false,
          cursor: nil,
          limit: nil
        ).call
      end

      expect(integration_select_count).to be <= 2
    end
  end

  def create_integration!(name:, host:)
    Integration.create!(
      kind: "radarr",
      name: name,
      base_url: "https://radarr.#{host}.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  def count_select_queries_for(table_name)
    count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      event_name = payload[:name].to_s
      next if event_name.in?(%w[SCHEMA TRANSACTION CACHE])
      next unless sql.match?(/\ASELECT\b/i)
      next unless sql.match?(/\b(?:FROM|JOIN)\s+\"?#{Regexp.escape(table_name)}\"?\b/i)

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    count
  end

  def capture_select_sql
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      event_name = payload[:name].to_s
      next if event_name.in?(%w[SCHEMA TRANSACTION CACHE])
      next unless sql.match?(/\bSELECT\b/i)

      statements << sql
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    statements
  end
end
# rubocop:enable RSpec/ExampleLength
