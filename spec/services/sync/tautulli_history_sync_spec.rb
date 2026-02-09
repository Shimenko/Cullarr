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
      settings_json: {}
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
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-tautulli").call

    stat = WatchStat.find_by!(plex_user: plex_user, watchable: movie)
    expect(result).to include(rows_fetched: 1, rows_processed: 1, watch_stats_upserted: 1)
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
      settings_json: {}
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
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-ambiguous-history").call

    expect(result).to include(
      rows_fetched: 1,
      rows_processed: 0,
      rows_ambiguous: 1,
      rows_skipped: 0,
      watch_stats_upserted: 0
    )
    expect(WatchStat.where(plex_user: plex_user)).to be_empty
    expect(tautulli_integration.reload.settings_json.dig("history_sync_state", "watermark_id")).to eq(5001)
  end
end
# rubocop:enable RSpec/ExampleLength
