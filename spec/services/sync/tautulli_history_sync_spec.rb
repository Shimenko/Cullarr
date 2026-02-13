require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Sync::TautulliHistorySync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual") }

  it "falls back to play_count mode when percent watched duration is missing" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Sync",
      base_url: "https://tautulli.sync.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 200 }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 10, friendly_name: "Alice", is_hidden: false)
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Sync",
      base_url: "https://radarr.sync.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(integration: movie_integration, radarr_movie_id: 701, title: "Example Movie", plex_rating_key: "plex-movie-701")

    AppSetting.find_or_create_by!(key: "watched_mode") { |setting| setting.value_json = "play_count" }
    AppSetting.find_or_create_by!(key: "watched_percent_threshold") { |setting| setting.value_json = 90 }
    AppSetting.find_or_create_by!(key: "in_progress_min_offset_ms") { |setting| setting.value_json = 1 }
    AppSetting.where(key: "watched_mode").update_all(value_json: "percent")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 1001,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: movie.plex_rating_key,
            viewed_at: Time.zone.parse("2026-02-09 08:00:00"),
            play_count: 1,
            view_offset_ms: 2_000_000,
            duration_ms: nil
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-tautulli").call

    stat = WatchStat.find_by!(plex_user: plex_user, watchable: movie)
    expect(result).to include(rows_fetched: 1, rows_processed: 1, rows_invalid: 0, watch_stats_upserted: 1)
    expect(stat.play_count).to eq(1)
    expect(stat.watched).to be(true)
    expect(stat.in_progress).to be(false)
    expect(tautulli_integration.reload.settings_json.dig("history_sync_state", "watermark_id")).to eq(1001)
  end

  it "skips ambiguous rating-key mappings without writing watch stats" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Ambiguous",
      base_url: "https://tautulli.ambiguous.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 200 }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 44, friendly_name: "Bob", is_hidden: false)
    radarr_a = Integration.create!(
      kind: "radarr",
      name: "Radarr A",
      base_url: "https://radarr-a.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr_b = Integration.create!(
      kind: "radarr",
      name: "Radarr B",
      base_url: "https://radarr-b.local",
      api_key: "secret",
      verify_ssl: true
    )
    Movie.create!(integration: radarr_a, radarr_movie_id: 1001, title: "One", plex_rating_key: "dup-key-1")
    Movie.create!(integration: radarr_b, radarr_movie_id: 1002, title: "Two", plex_rating_key: "dup-key-1")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 5001,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: "dup-key-1",
            viewed_at: Time.zone.parse("2026-02-09 09:30:00"),
            play_count: 1,
            view_offset_ms: 1_000_000,
            duration_ms: 1_500_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-ambiguous-history").call

    expect(result).to include(
      rows_fetched: 1,
      rows_processed: 0,
      rows_invalid: 0,
      rows_ambiguous: 1,
      rows_skipped: 0,
      watch_stats_upserted: 0,
      history_state_updates: 0,
      history_state_skipped: 1,
      degraded_zero_processed: 1
    )
    expect(WatchStat.where(plex_user: plex_user)).to be_empty
    expect(tautulli_integration.reload.settings_json).not_to have_key("history_sync_state")
  end

  it "continues processing when a page includes invalid rows" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Mixed History",
      base_url: "https://tautulli.mixed.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 200 }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 77, friendly_name: "Carol", is_hidden: false)
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Mixed",
      base_url: "https://radarr.mixed.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(integration: movie_integration, radarr_movie_id: 1701, title: "Mixed Movie", plex_rating_key: "plex-mixed-1701")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 7101,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: movie.plex_rating_key,
            viewed_at: Time.zone.parse("2026-02-10 13:00:00"),
            play_count: 1,
            view_offset_ms: 500_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 1,
        has_more: false,
        next_start: 2
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-mixed-history").call

    expect(result).to include(
      rows_fetched: 2,
      rows_processed: 1,
      rows_invalid: 1,
      rows_skipped: 1,
      watch_stats_upserted: 1
    )
  end

  it "advances watermark only from persisted rows while keeping max_seen for scan horizon" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Watermark Safety",
      base_url: "https://tautulli.watermark.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 200 }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 88, friendly_name: "Dana", is_hidden: false)
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Watermark Safety",
      base_url: "https://radarr.watermark.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: movie_integration,
      radarr_movie_id: 1801,
      title: "Watermark Movie",
      plex_rating_key: "plex-watermark-1801"
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 9102,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: "missing-rating-key",
            viewed_at: Time.zone.parse("2026-02-11 10:00:00"),
            play_count: 1,
            view_offset_ms: 800_000,
            duration_ms: 1_000_000
          },
          {
            history_id: 9101,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: movie.plex_rating_key,
            viewed_at: Time.zone.parse("2026-02-11 09:00:00"),
            play_count: 1,
            view_offset_ms: 900_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 2
      }
    )

    result = described_class.new(sync_run: sync_run, correlation_id: "corr-watermark-safety").call

    expect(result).to include(
      rows_fetched: 2,
      rows_processed: 1,
      rows_skipped_missing_watchable: 1,
      watch_stats_upserted: 1
    )
    state = tautulli_integration.reload.settings_json.fetch("history_sync_state")
    expect(state.fetch("watermark_id")).to eq(9101)
    expect(state.fetch("max_seen_history_id")).to eq(9102)
  end

  it "continues pagination when early pages are below overlap bound but later pages contain new history ids" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Non Monotonic",
      base_url: "https://tautulli.non-monotonic.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "tautulli_history_page_size" => 2,
        "history_sync_state" => { "watermark_id" => 0, "max_seen_history_id" => 2_000, "recent_ids" => [] }
      }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 99, friendly_name: "Eve", is_hidden: false)
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Non Monotonic",
      base_url: "https://radarr.non-monotonic.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: movie_integration,
      radarr_movie_id: 1_901,
      title: "Non Monotonic Movie",
      plex_rating_key: "plex-non-monotonic-1901"
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 50,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 1_850,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: "older-row",
            viewed_at: Time.zone.parse("2026-02-11 08:00:00"),
            play_count: 1,
            view_offset_ms: 500_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 1,
        has_more: true,
        next_start: 2
      }
    )
    allow(adapter).to receive(:fetch_history_page).with(
      start: 2,
      length: 50,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 2_050,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: movie.plex_rating_key,
            viewed_at: Time.zone.parse("2026-02-11 09:00:00"),
            play_count: 1,
            view_offset_ms: 900_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 3
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-non-monotonic").call

    expect(result).to include(rows_fetched: 3, rows_processed: 1, watch_stats_upserted: 1)
    expect(WatchStat.where(plex_user:, watchable: movie).count).to eq(1)
  end

  it "reconciles missing plex mappings via tautulli metadata external ids" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Metadata Reconcile",
      base_url: "https://tautulli.reconcile.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 200 }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 121, friendly_name: "Frank", is_hidden: false)
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Metadata Reconcile",
      base_url: "https://radarr.reconcile.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: movie_integration,
      radarr_movie_id: 2_001,
      title: "Needs Mapping",
      tmdb_id: 2_001,
      plex_rating_key: nil,
      plex_guid: nil
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 12_001,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: "plex-new-2001",
            viewed_at: Time.zone.parse("2026-02-11 11:00:00"),
            play_count: 1,
            view_offset_ms: 900_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-new-2001").and_return(
      {
        duration_ms: 1_000_000,
        plex_guid: "plex://movie/2001",
        file_path: "/mnt/media/movies/Needs Mapping (2001)/movie.mkv",
        external_ids: { tmdb_id: 2_001 },
        provenance: {
          endpoint: "get_metadata",
          feed_role: "enrichment_verification",
          source_strength: "strong_enrichment",
          integration_name: tautulli_integration.name,
          integration_kind: tautulli_integration.kind,
          integration_id: tautulli_integration.id,
          signals: {
            file_path: { source: "metadata_media_info_parts_file", raw: "/mnt/media/movies/Needs Mapping (2001)/movie.mkv", normalized: "/mnt/media/movies/Needs Mapping (2001)/movie.mkv", value: "/mnt/media/movies/Needs Mapping (2001)/movie.mkv" },
            imdb_id: { source: "none", raw: nil, normalized: nil, value: nil },
            tmdb_id: { source: "metadata_guids", raw: "tmdb://2001", normalized: 2_001, value: 2_001 },
            tvdb_id: { source: "none", raw: nil, normalized: nil, value: nil }
          }
        }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-reconcile").call

    expect(result).to include(rows_processed: 1, watch_stats_upserted: 1, rows_skipped_missing_watchable: 0)
    expect(movie.reload.plex_rating_key).to eq("plex-new-2001")
    expect(movie.reload.plex_guid).to eq("plex://movie/2001")
    expect(movie.reload.metadata_json).not_to have_key("provenance")
    expect(WatchStat.where(plex_user:, watchable: movie).count).to eq(1)
  end

  it "resolves episode mappings by series metadata before episode-level metadata fallback" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Episode Series Mapping",
      base_url: "https://tautulli.episode-series.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "tautulli_history_page_size" => 200,
        "tautulli_metadata_workers" => 1
      }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 199, friendly_name: "Hank", is_hidden: false)
    sonarr_integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Episode Series Mapping",
      base_url: "https://sonarr.episode-series.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr_integration,
      sonarr_series_id: 3_301,
      title: "Series Match",
      tvdb_id: 3_301
    )
    season = Season.create!(series: series, season_number: 2)
    episode = Episode.create!(
      integration: sonarr_integration,
      season: season,
      sonarr_episode_id: 33_012,
      episode_number: 5,
      title: "Needs Episode Mapping",
      plex_rating_key: nil
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 13_301,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "episode",
            plex_rating_key: "plex-episode-33012",
            plex_grandparent_rating_key: "plex-show-3301",
            season_number: 2,
            episode_number: 5,
            viewed_at: Time.zone.parse("2026-02-11 11:30:00"),
            play_count: 1,
            view_offset_ms: 1_100_000,
            duration_ms: 1_300_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )
    allow(adapter).to receive(:fetch_metadata) do |rating_key:|
      raise "unexpected episode-level metadata lookup for #{rating_key}" unless rating_key == "plex-show-3301"

      {
        duration_ms: nil,
        plex_guid: "plex://show/3301",
        external_ids: { tvdb_id: 3_301 }
      }
    end

    result = described_class.new(sync_run:, correlation_id: "corr-episode-series-reconcile").call

    expect(result).to include(rows_processed: 1, watch_stats_upserted: 1, metadata_lookup_attempted: 1)
    expect(episode.reload.plex_rating_key).to eq("plex-episode-33012")
    expect(WatchStat.where(plex_user:, watchable: episode).count).to eq(1)
  end

  it "rescans from a reset watermark when stored history state is stale" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Stale State",
      base_url: "https://tautulli.stale.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "tautulli_history_page_size" => 200,
        "history_sync_state" => { "watermark_id" => 0, "max_seen_history_id" => 50_000, "recent_ids" => [] }
      }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 141, friendly_name: "Grace", is_hidden: false)
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Stale State",
      base_url: "https://radarr.stale.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: movie_integration,
      radarr_movie_id: 2_101,
      title: "Stale State Movie",
      plex_rating_key: "plex-stale-2101"
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 10,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: movie.plex_rating_key,
            viewed_at: Time.zone.parse("2026-02-11 12:00:00"),
            play_count: 1,
            view_offset_ms: 500_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      },
      {
        rows: [
          {
            history_id: 12,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: movie.plex_rating_key,
            viewed_at: Time.zone.parse("2026-02-11 12:05:00"),
            play_count: 1,
            view_offset_ms: 750_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-stale-state").call

    expect(result).to include(rows_processed: 1, watch_stats_upserted: 1)
    state = tautulli_integration.reload.settings_json.fetch("history_sync_state")
    expect(state.fetch("watermark_id")).to eq(12)
    expect(state.fetch("max_seen_history_id")).to eq(12)
  end

  it "does not advance scan horizon when no rows are persisted from fetched history" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Preserve Horizon",
      base_url: "https://tautulli.horizon.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "tautulli_history_page_size" => 200,
        "history_sync_state" => { "watermark_id" => 25, "max_seen_history_id" => 99, "recent_ids" => [] }
      }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 155, friendly_name: "Horizon User", is_hidden: false)

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_raise(Integrations::ContractMismatchError, "metadata unavailable")
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 2_001,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: "unknown-rating-key",
            viewed_at: Time.zone.parse("2026-02-11 12:00:00"),
            play_count: 1,
            view_offset_ms: 700_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-preserve-horizon").call

    expect(result).to include(
      rows_fetched: 1,
      rows_processed: 0,
      rows_skipped_missing_watchable: 1,
      history_state_updates: 0,
      history_state_skipped: 1,
      degraded_zero_processed: 1
    )
    state = tautulli_integration.reload.settings_json.fetch("history_sync_state")
    expect(state).to include("watermark_id" => 25, "max_seen_history_id" => 99)
  end

  it "streams progress during metadata reconciliation and row evaluation" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Progress Streaming",
      base_url: "https://tautulli.progress.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 200 }
    )
    plex_user = PlexUser.create!(tautulli_user_id: 166, friendly_name: "Progress User", is_hidden: false)
    progress_events = []
    phase_progress = instance_double(Sync::ProgressTracker)
    allow(phase_progress).to receive(:add_total!) { |count| progress_events << [ :add_total, count ] }
    allow(phase_progress).to receive(:advance!) { |count| progress_events << [ :advance, count ] }

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_history_page).with(
      start: 0,
      length: 200,
      order_column: "id",
      order_dir: "desc"
    ).and_return(
      {
        rows: [
          {
            history_id: 30_001,
            tautulli_user_id: plex_user.tautulli_user_id,
            media_type: "movie",
            plex_rating_key: "unmapped-rating-key",
            viewed_at: Time.zone.parse("2026-02-11 12:00:00"),
            play_count: 1,
            view_offset_ms: 750_000,
            duration_ms: 1_000_000
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        has_more: false,
        next_start: 1
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "unmapped-rating-key").and_return(
      {
        duration_ms: 1_000_000,
        plex_guid: "plex://movie/30001",
        external_ids: {}
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-progress-stream", phase_progress: phase_progress).call

    expect(result).to include(
      rows_fetched: 1,
      rows_processed: 0,
      rows_skipped_missing_watchable: 1,
      metadata_lookup_attempted: 1
    )
    expect(progress_events).to include([ :add_total, 2 ], [ :add_total, 1 ])
    expect(progress_events.count { |event| event == [ :advance, 1 ] }).to be >= 3
  end
end
# rubocop:enable RSpec/ExampleLength
