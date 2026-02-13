require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ReceiveMessages
RSpec.describe Sync::TautulliLibraryMappingSync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual") }

  it "maps watchables by canonical file path and persists library mapping state" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Mapping",
      base_url: "https://tautulli.mapping.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 100 }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Mapping",
      base_url: "https://radarr.mapping.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 42,
      title: "Mapped Movie",
      metadata_json: {}
    )
    MediaFile.create!(
      attachable: movie,
      integration: radarr,
      arr_file_id: 4200,
      path: "/data/movies/Mapped Movie/movie.mkv",
      path_canonical: "/mnt/movies/Mapped Movie/movie.mkv",
      size_bytes: 1000,
      quality_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 10, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 10, start: 0, length: 100).and_return(
      {
        rows: [
          {
            media_type: "movie",
            plex_rating_key: "plex-movie-42",
            plex_guid: "plex://movie/42",
            file_path: "/mnt/movies/Mapped Movie/movie.mkv",
            external_ids: { imdb_id: "tt424242" }
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-path").call

    expect(result).to include(
      integrations: 1,
      libraries_fetched: 1,
      rows_fetched: 1,
      rows_processed: 1,
      rows_mapped_by_path: 1,
      watchables_updated: 1,
      state_updates: 1
    )
    movie.reload
    expect(movie.plex_rating_key).to eq("plex-movie-42")
    expect(movie.plex_guid).to eq("plex://movie/42")
    expect(movie.mapping_status_code).to eq("verified_path")
    expect(movie.mapping_strategy).to eq("path_match")
    expect(movie.mapping_status_changed_at).to be_present
    expect(movie.mapping_diagnostics_json).to include("version" => "v2", "selected_step" => "path")

    state = tautulli.reload.settings_json.fetch("library_mapping_state")
    expect(state["last_run_at"]).to be_present
    expect(state.dig("libraries", "10", "next_start")).to eq(0)
    expect(state.dig("libraries", "10", "completed_cycle_count")).to eq(1)
  end

  it "falls back to external ids when path data is unavailable" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli External Mapping",
      base_url: "https://tautulli.external.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 100 }
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr External Mapping",
      base_url: "https://sonarr.external.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 700,
      title: "External Show"
    )
    season = Season.create!(series: series, season_number: 1)
    episode = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 701,
      episode_number: 1,
      tvdb_id: 123_456,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 20, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 20, start: 0, length: 100).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-701",
            plex_guid: "plex://episode/701",
            external_ids: { tvdb_id: 123_456 }
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-external").call

    expect(result).to include(rows_mapped_by_external_ids: 1, watchables_updated: 1, rows_ambiguous: 0)
    episode.reload
    expect(episode.plex_rating_key).to eq("plex-episode-701")
    expect(episode.plex_guid).to eq("plex://episode/701")
    expect(episode.mapping_status_code).to eq("verified_external_ids")
    expect(episode.mapping_strategy).to eq("external_ids_match")
    expect(episode.mapping_diagnostics_json).to include("version" => "v2", "selected_step" => "external_ids")
  end

  it "marks ambiguous mapping on external-id conflicts without overriding existing plex rating keys" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Ambiguous Mapping",
      base_url: "https://tautulli.ambiguous-mapping.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 100 }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Ambiguous Mapping",
      base_url: "https://radarr.ambiguous-mapping.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 909,
      title: "Existing Key Movie",
      imdb_id: "tt0909090",
      plex_rating_key: "plex-old-key",
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 30, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 30, start: 0, length: 100).and_return(
      {
        rows: [
          {
            media_type: "movie",
            plex_rating_key: "plex-new-key",
            external_ids: { imdb_id: "tt0909090" }
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-ambiguous").call

    expect(result).to include(rows_ambiguous: 1, rows_mapped_by_external_ids: 0)
    movie.reload
    expect(movie.plex_rating_key).to eq("plex-old-key")
    expect(movie.mapping_status_code).to eq("ambiguous_conflict")
    expect(movie.mapping_strategy).to eq("conflict_detected")
    expect(movie.mapping_diagnostics_json["conflict_reason"]).to eq("plex_rating_key_conflict")
  end

  it "falls back to unique movie title and year when path and external ids are missing" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Title/Year Mapping",
      base_url: "https://tautulli.title-year.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 100 }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Title/Year Mapping",
      base_url: "https://radarr.title-year.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 6_001,
      title: "Fallback Matched Movie",
      year: 2024,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 40, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 40, start: 0, length: 100).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Fallback Matched Movie",
            year: 2024,
            plex_rating_key: "plex-movie-6001",
            plex_guid: "plex://movie/6001",
            plex_added_at: "2024-10-09T01:54:18Z",
            external_ids: {}
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-title-year").call

    expect(result).to include(rows_mapped_by_title_year: 1, watchables_updated: 1, rows_unmapped: 0)
    movie.reload
    expect(movie.plex_rating_key).to eq("plex-movie-6001")
    expect(movie.plex_guid).to eq("plex://movie/6001")
    expect(movie.mapping_status_code).to eq("provisional_title_year")
    expect(movie.mapping_strategy).to eq("title_year_fallback")
    expect(movie.metadata_json["plex_added_at"]).to eq("2024-10-09T01:54:18Z")
  end

  it "keeps mapping semantics unchanged when discovery rows include provenance markers" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Provenance Mapping",
      base_url: "https://tautulli.provenance.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 100 }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Provenance Mapping",
      base_url: "https://radarr.provenance.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 6_101,
      title: "Provenance Fallback Movie",
      year: 2025,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 41, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 41, start: 0, length: 100).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Provenance Fallback Movie",
            year: 2025,
            plex_rating_key: "plex-movie-6101",
            external_ids: {},
            provenance: {
              endpoint: "get_library_media_info",
              feed_role: "discovery",
              source_strength: "sparse_discovery"
            }
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-provenance-no-drift").call

    expect(result).to include(rows_mapped_by_title_year: 1, rows_ambiguous: 0, rows_unmapped: 0)
    movie.reload
    expect(movie.mapping_status_code).to eq("provisional_title_year")
    expect(movie.mapping_strategy).to eq("title_year_fallback")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ReceiveMessages
