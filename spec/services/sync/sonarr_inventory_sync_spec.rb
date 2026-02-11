require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/ReceiveMessages
RSpec.describe Sync::SonarrInventorySync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual") }

  it "upserts sonarr inventory into normalized tables" do
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Sync",
      base_url: "https://sonarr.sync.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "sonarr_fetch_workers" => 1 }
    )
    PathMapping.create!(
      integration: integration,
      from_prefix: "/data",
      to_prefix: "/mnt"
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::SonarrAdapter)
    allow(Integrations::SonarrAdapter).to receive(:new).with(integration: integration).and_return(adapter)
    allow(adapter).to receive(:fetch_series).and_return(
      [
        {
          sonarr_series_id: 101,
          title: "Example Show",
          year: 2020,
          tvdb_id: 123,
          imdb_id: "tt001",
          tmdb_id: 456,
          plex_rating_key: "plex-show-101",
          plex_guid: "plex://show/101",
          statistics: { total_episode_count: 1, episode_file_count: 1 },
          metadata: {}
        }
      ]
    )
    allow(adapter).to receive(:fetch_episodes).and_return(
      [
        {
          sonarr_episode_id: 5001,
          season_number: 1,
          episode_number: 1,
          title: "Pilot",
          air_date: "2020-01-01",
          duration_ms: 3_000_000,
          tvdb_id: 901,
          imdb_id: "tt901",
          tmdb_id: 2901,
          plex_rating_key: "plex-ep-5001",
          plex_guid: "plex://episode/5001",
          external_ids: { tvdb_id: 901 }
        }
      ]
    )
    allow(adapter).to receive(:fetch_episode_files).and_return(
      [
        {
          arr_file_id: 9001,
          sonarr_episode_id: 5001,
          path: "/data/tv/Example Show/Season 01/Pilot.mkv",
          size_bytes: 734_003_200,
          quality: {}
        }
      ]
    )

    result = described_class.new(sync_run:, correlation_id: "corr-sonarr").call

    expect(result).to include(series_fetched: 1, episodes_fetched: 1, media_files_fetched: 1)
    expect(Series.find_by!(integration: integration, sonarr_series_id: 101).title).to eq("Example Show")
    episode = Episode.find_by!(integration: integration, sonarr_episode_id: 5001)
    media_file = MediaFile.find_by!(integration: integration, arr_file_id: 9001)
    expect(media_file.attachable).to eq(episode)
    expect(media_file.path_canonical).to eq("/mnt/tv/Example Show/Season 01/Pilot.mkv")
  end

  it "stores canonical paths with separator-safe structure under root mappings" do
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Root Mapping",
      base_url: "https://sonarr.root.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "sonarr_fetch_workers" => 1 }
    )
    PathMapping.create!(integration:, from_prefix: "/", to_prefix: "/mnt")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::SonarrAdapter)
    allow(Integrations::SonarrAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_series).and_return(
      [
        {
          sonarr_series_id: 202,
          title: "Root Mapping Show",
          statistics: { total_episode_count: 1, episode_file_count: 1 },
          metadata: {}
        }
      ]
    )
    allow(adapter).to receive(:fetch_episodes).with(series_id: 202).and_return(
      [
        {
          sonarr_episode_id: 5202,
          season_number: 1,
          episode_number: 2,
          title: "Second",
          metadata: {}
        }
      ]
    )
    allow(adapter).to receive(:fetch_episode_files).with(series_id: 202).and_return(
      [
        {
          arr_file_id: 9202,
          sonarr_episode_id: 5202,
          path: "/shows/Root Mapping Show/Season 01/Second.mkv",
          size_bytes: 800,
          quality: {}
        }
      ]
    )

    described_class.new(sync_run:, correlation_id: "corr-sonarr-root").call

    media_file = MediaFile.find_by!(integration:, arr_file_id: 9202)
    expect(media_file.path_canonical).to eq("/mnt/shows/Root Mapping Show/Season 01/Second.mkv")
  end

  it "seeds phase totals from series statistics before processing children" do
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Estimated Totals",
      base_url: "https://sonarr.estimated.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "sonarr_fetch_workers" => 1 }
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::SonarrAdapter)
    allow(Integrations::SonarrAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_series).and_return(
      [
        {
          sonarr_series_id: 303,
          title: "Estimated Show",
          statistics: { total_episode_count: 2, episode_file_count: 1 },
          metadata: {}
        }
      ]
    )
    allow(adapter).to receive(:fetch_episodes).with(series_id: 303).and_return(
      [
        { sonarr_episode_id: 7301, season_number: 1, episode_number: 1 },
        { sonarr_episode_id: 7302, season_number: 1, episode_number: 2 }
      ]
    )
    allow(adapter).to receive(:fetch_episode_files).with(series_id: 303).and_return(
      [
        {
          arr_file_id: 9901,
          sonarr_episode_id: 7301,
          path: "/data/tv/Estimated/one.mkv",
          size_bytes: 1,
          quality: {}
        }
      ]
    )

    progress_events = []
    phase_progress = instance_double(Sync::ProgressTracker)
    allow(phase_progress).to receive(:add_total!) { |count| progress_events << [ :add_total, count ] }
    allow(phase_progress).to receive(:advance!) { |count| progress_events << [ :advance, count ] }

    described_class.new(sync_run:, correlation_id: "corr-sonarr-estimated", phase_progress: phase_progress).call

    expect(progress_events).to include([ :add_total, 4 ])
    expect(progress_events).to include([ :advance, 1 ])
    expect(progress_events).to include([ :advance, 3 ])
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/ReceiveMessages
