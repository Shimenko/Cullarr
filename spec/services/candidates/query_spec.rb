require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
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

    it "classifies v2 mapping statuses for movie candidates" do
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
        mapping_status_code: "provisional_title_year",
        mapping_strategy: "title_year_fallback",
        mapping_status_changed_at: Time.current
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
      expect(rows_by_title.dig("Missing IDs Movie", :mapping_status, :code)).to eq("unresolved")
      expect(rows_by_title.dig("Missing IDs Movie", :mapping_status, :state)).to eq("unresolved")
      expect(rows_by_title.dig("Path Mismatch Movie", :mapping_status, :code)).to eq("unresolved")
      expect(rows_by_title.dig("Low Confidence Movie", :mapping_status, :code)).to eq("provisional_title_year")
      expect(rows_by_title.dig("Low Confidence Movie", :mapping_status, :state)).to eq("provisional")
      expect(rows_by_title.dig("Low Confidence Movie", :mapping_status, :details)).to be_present
      expect(rows_by_title.dig("Low Confidence Movie", :mapping_diagnostics, "kind")).to eq("watchable")
      expect(rows_by_title.dig("Low Confidence Movie", :mapping_diagnostics, "verification_outcomes")).to eq(
        "path" => "failed",
        "external_ids" => "failed",
        "tv_structure" => "not_applicable",
        "title_year" => "passed"
      )
    end

    it "keeps verified_path outward status verified when plex rating key is blank" do
      integration = create_integration!(name: "Radarr Verified Path Sparse", host: "verified-path-sparse")
      user = PlexUser.create!(tautulli_user_id: 109, friendly_name: "Sparse Key User", is_hidden: false)
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_010,
        title: "Sparse Path Movie",
        plex_rating_key: nil,
        imdb_id: "tt07010",
        tmdb_id: 7010,
        mapping_status_code: "verified_path",
        mapping_strategy: "path_match",
        mapping_status_changed_at: Time.current
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 8_010,
        path: "/media/movies/sparse-path.mkv",
        path_canonical: "/media/movies/sparse-path.mkv",
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
      expect(row.dig(:mapping_status, :code)).to eq("verified_path")
      expect(row.dig(:mapping_status, :state)).to eq("verified")
      expect(row.dig(:mapping_diagnostics, "verification_outcomes")).to eq(
        "path" => "passed",
        "external_ids" => "skipped",
        "tv_structure" => "not_applicable",
        "title_year" => "skipped"
      )
    end

    it "does not override v2 mapping status with legacy external_id_mismatch metadata flag" do
      integration = create_integration!(name: "Radarr ID Mismatch", host: "id-mismatch")
      user = PlexUser.create!(tautulli_user_id: 110, friendly_name: "ID Mismatch User", is_hidden: false)
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_011,
        title: "ID Mismatch Movie",
        plex_rating_key: "plex-7011",
        mapping_status_code: "verified_external_ids",
        mapping_strategy: "external_ids_match",
        mapping_status_changed_at: Time.current,
        metadata_json: { "external_id_mismatch" => true }
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 8_011,
        path: "/media/movies/id-mismatch.mkv",
        path_canonical: "/media/movies/id-mismatch.mkv",
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
      expect(row.dig(:mapping_status, :code)).to eq("verified_external_ids")
      expect(row.dig(:mapping_status, :state)).to eq("verified")
      expect(row[:risk_flags]).to include("external_id_mismatch")
    end

    it "keeps ambiguous_conflict precedence over external_id_mismatch" do
      integration = create_integration!(name: "Radarr Ambiguous Precedence", host: "ambiguous-precedence")
      user = PlexUser.create!(tautulli_user_id: 111, friendly_name: "Ambiguous Precedence User", is_hidden: false)
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_012,
        title: "Ambiguous Precedence Movie",
        mapping_status_code: "ambiguous_conflict",
        mapping_strategy: "conflict_detected",
        mapping_status_changed_at: Time.current,
        metadata_json: { "external_id_mismatch" => true }
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 8_012,
        path: "/media/movies/ambiguous-precedence.mkv",
        path_canonical: "/media/movies/ambiguous-precedence.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "movie:#{movie.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("ambiguous_conflict")
      expect(row.dig(:mapping_status, :state)).to eq("ambiguous")
      expect(row[:blocker_flags]).to include("ambiguous_mapping")
    end

    it "maps verified_tv_structure directly to v2 outward contract" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr TV Structure Freeze",
        base_url: "https://sonarr.tv-structure-freeze.local",
        api_key: "secret",
        verify_ssl: true
      )
      user = PlexUser.create!(tautulli_user_id: 114, friendly_name: "TV Structure User", is_hidden: false)
      series = Series.create!(integration:, sonarr_series_id: 41_001, title: "TV Structure Show")
      season = Season.create!(series:, season_number: 1)
      episode = Episode.create!(
        integration: integration,
        season: season,
        sonarr_episode_id: 41_101,
        episode_number: 1,
        plex_rating_key: "plex-41101",
        mapping_status_code: "verified_tv_structure",
        mapping_strategy: "tv_structure_match",
        mapping_status_changed_at: Time.current
      )
      MediaFile.create!(
        attachable: episode,
        integration: integration,
        arr_file_id: 51_101,
        path: "/media/tv/tv-structure-freeze.mkv",
        path_canonical: "/media/tv/tv-structure-freeze.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)

      result = described_class.new(
        scope: "tv_episode",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "episode:#{episode.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("verified_tv_structure")
      expect(row.dig(:mapping_status, :state)).to eq("verified")
      expect(row.dig(:mapping_diagnostics, "verification_outcomes")).to eq(
        "path" => "failed",
        "external_ids" => "failed",
        "tv_structure" => "passed",
        "title_year" => "not_applicable"
      )
    end

    it "keeps external_source_not_managed explicit in outward contract" do
      integration = create_integration!(name: "Radarr External Source Freeze", host: "external-source-freeze")
      user = PlexUser.create!(tautulli_user_id: 115, friendly_name: "External Source User", is_hidden: false)
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_014,
        title: "External Source Movie",
        imdb_id: "tt07014",
        tmdb_id: 7014,
        mapping_status_code: "external_source_not_managed",
        mapping_strategy: "external_unmanaged_path",
        mapping_status_changed_at: Time.current
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 8_014,
        path: "/external/media/movies/external-source.mkv",
        path_canonical: "/external/media/movies/external-source.mkv",
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
      expect(row.dig(:mapping_status, :code)).to eq("external_source_not_managed")
      expect(row.dig(:mapping_status, :state)).to eq("external")
    end

    it "ignores legacy mapping booleans when first-class mapping status disagrees" do
      integration = create_integration!(name: "Radarr Legacy Disagreement", host: "legacy-disagreement")
      user = PlexUser.create!(tautulli_user_id: 116, friendly_name: "Legacy Disagreement User", is_hidden: false)
      movie = Movie.create!(
        integration: integration,
        radarr_movie_id: 7_013,
        title: "Legacy Disagreement Movie",
        plex_rating_key: nil,
        imdb_id: "tt07013",
        tmdb_id: 7013,
        mapping_status_code: "unresolved",
        mapping_strategy: "no_match",
        metadata_json: {
          "low_confidence_mapping" => true,
          "ambiguous_mapping" => true
        }
      )
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 8_013,
        path: "/media/movies/legacy-disagreement.mkv",
        path_canonical: "/media/movies/legacy-disagreement.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)

      result = described_class.new(
        scope: "movie",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "movie:#{movie.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("unresolved")
      expect(row.dig(:mapping_status, :state)).to eq("unresolved")
      expect(row[:risk_flags]).not_to include("low_confidence_mapping")
      expect(row[:blocker_flags]).not_to include("ambiguous_mapping")
    end

    it "uses fail-closed precedence for season rollup mapping statuses" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Rollup Status Season",
        base_url: "https://sonarr.rollup-status-season.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 21_001, title: "Rollup Status Season")
      season = Season.create!(series: series, season_number: 1)
      provisional_episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 21_101,
        episode_number: 1,
        duration_ms: 100_000,
        mapping_status_code: "provisional_title_year",
        mapping_strategy: "title_year_fallback",
        mapping_status_changed_at: Time.current
      )
      verified_episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 21_102,
        episode_number: 2,
        duration_ms: 100_000,
        plex_rating_key: "plex-21102",
        mapping_status_code: "verified_path",
        mapping_strategy: "path_match",
        mapping_status_changed_at: Time.current
      )

      [ provisional_episode, verified_episode ].each_with_index do |episode, index|
        MediaFile.create!(
          attachable: episode,
          integration: integration,
          arr_file_id: 31_100 + index,
          path: "/media/tv/rollup-status-season-#{index}.mkv",
          path_canonical: "/media/tv/rollup-status-season-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
      end

      user = PlexUser.create!(tautulli_user_id: 112, friendly_name: "Rollup Status Season User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: provisional_episode, play_count: 1)
      WatchStat.create!(plex_user: user, watchable: verified_episode, play_count: 1)

      result = described_class.new(
        scope: "tv_season",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "season:#{season.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("provisional_title_year")
      expect(row.dig(:mapping_status, :state)).to eq("provisional")
      expect(row.dig(:mapping_diagnostics, "kind")).to eq("rollup")
    end

    it "keeps verified rollup status when all episodes are verified_path" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Rollup Status Show",
        base_url: "https://sonarr.rollup-status-show.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 22_001, title: "Rollup Status Show")
      season = Season.create!(series: series, season_number: 1)
      episode = Episode.create!(
        season: season,
        integration: integration,
        sonarr_episode_id: 22_101,
        episode_number: 1,
        duration_ms: 100_000,
        plex_rating_key: "plex-22101",
        mapping_status_code: "verified_path",
        mapping_strategy: "path_match",
        mapping_status_changed_at: Time.current
      )
      MediaFile.create!(
        attachable: episode,
        integration: integration,
        arr_file_id: 32_101,
        path: "/media/tv/rollup-status-show.mkv",
        path_canonical: "/media/tv/rollup-status-show.mkv",
        size_bytes: 1.gigabyte
      )
      user = PlexUser.create!(tautulli_user_id: 113, friendly_name: "Rollup Status Show User", is_hidden: false)
      WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)

      result = described_class.new(
        scope: "tv_show",
        plex_user_ids: [ user.id ],
        include_blocked: false,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "show:#{series.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("verified_path")
      expect(row.dig(:mapping_status, :state)).to eq("verified")
    end

    it "emits deterministic rollup diagnostics keys and capped sorted episode IDs" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Rollup Diagnostics Keys",
        base_url: "https://sonarr.rollup-diagnostics-keys.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 23_001, title: "Rollup Diagnostics Show")
      season = Season.create!(series: series, season_number: 1)
      user = PlexUser.create!(tautulli_user_id: 117, friendly_name: "Rollup Diagnostics User", is_hidden: false)

      ambiguous_episode_ids = []
      6.times do |index|
        episode = Episode.create!(
          season: season,
          integration: integration,
          sonarr_episode_id: 23_100 + index,
          episode_number: index + 1,
          mapping_status_code: "ambiguous_conflict",
          mapping_strategy: "conflict_detected",
          duration_ms: 100_000
        )
        MediaFile.create!(
          attachable: episode,
          integration: integration,
          arr_file_id: 33_100 + index,
          path: "/media/tv/rollup-diagnostics-#{index}.mkv",
          path_canonical: "/media/tv/rollup-diagnostics-#{index}.mkv",
          size_bytes: 1.gigabyte
        )
        WatchStat.create!(plex_user: user, watchable: episode, play_count: 1)
        ambiguous_episode_ids << episode.id
      end

      result = described_class.new(
        scope: "tv_season",
        plex_user_ids: [ user.id ],
        include_blocked: true,
        watched_match_mode: "all",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "season:#{season.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("ambiguous_conflict")

      diagnostics = row.fetch(:mapping_diagnostics)
      expected_status_keys = %w[
        verified_path
        verified_external_ids
        verified_tv_structure
        provisional_title_year
        external_source_not_managed
        unresolved
        ambiguous_conflict
      ]
      expect(diagnostics.fetch("status_counts").keys).to match_array(expected_status_keys)
      expect(diagnostics.fetch("worst_status_episode_ids").keys).to match_array(expected_status_keys)
      expect(diagnostics.fetch("id_cap_per_status")).to eq(5)
      expect(diagnostics.fetch("rollup_reason")).to eq("all_episodes_single_status")
      expected_capped_ids = ambiguous_episode_ids.sort.first(5)
      expect(diagnostics.dig("worst_status_episode_ids", "ambiguous_conflict")).to eq(expected_capped_ids)
    end

    it "emits no_episode_media_files rollup reason for empty rollup inputs" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Empty Rollup",
        base_url: "https://sonarr.empty-rollup.local",
        api_key: "secret",
        verify_ssl: true
      )
      series = Series.create!(integration: integration, sonarr_series_id: 24_001, title: "Empty Rollup Show")
      season = Season.create!(series: series, season_number: 1)

      result = described_class.new(
        scope: "tv_season",
        plex_user_ids: [],
        include_blocked: true,
        watched_match_mode: "none",
        cursor: nil,
        limit: nil
      ).call

      row = result.items.find { |item| item[:candidate_id] == "season:#{season.id}" }
      expect(row.dig(:mapping_status, :code)).to eq("unresolved")
      expect(row.dig(:mapping_status, :state)).to eq("unresolved")
      expect(row.dig(:mapping_diagnostics, "total_episode_count")).to eq(0)
      expect(row.dig(:mapping_diagnostics, "rollup_reason")).to eq("no_episode_media_files")
      expect(row.dig(:mapping_diagnostics, "worst_status_code")).to eq("unresolved")
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
