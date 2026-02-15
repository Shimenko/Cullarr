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
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
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
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
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
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
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
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-movie-6001").and_return(nil)
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
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-movie-6101").and_return(nil)
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

  it "promotes provisional title/year matches when recheck finds same watchable by strong ids" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Provisional Promote",
      base_url: "https://tautulli.promote.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Provisional Promote",
      base_url: "https://radarr.promote.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_101,
      title: "Promoted Movie",
      year: 2024,
      imdb_id: "tt7101",
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 51, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 51, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Promoted Movie",
            year: 2024,
            plex_rating_key: "plex-promote-7101",
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
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-promote-7101").and_return(
      {
        file_path: nil,
        external_ids: { imdb_id: "tt7101" },
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-promote").call

    movie.reload
    expect(movie.mapping_status_code).to eq("verified_external_ids")
    expect(movie.mapping_strategy).to eq("external_ids_match")
    expect(movie.mapping_diagnostics_json.fetch("tv_structure")).to include(
      "outcome" => "not_applicable_non_tv",
      "fallback_path" => nil
    )
    expect(result).to include(
      provisional_seen: 1,
      provisional_rechecked: 1,
      provisional_promoted: 1,
      provisional_conflicted: 0,
      provisional_still_provisional: 0,
      metadata_recheck_attempted: 1,
      metadata_recheck_failed: 0,
      metadata_recheck_skipped: 0,
      recheck_eligible_rows: 1,
      enrichment_watchable_get_metadata_attempted: 1,
      enrichment_watchable_get_metadata_skipped: 0,
      enrichment_watchable_get_metadata_failed: 0,
      enrichment_show_get_metadata_attempted: 0,
      enrichment_show_get_metadata_skipped: 0,
      enrichment_show_get_metadata_failed: 0,
      enrichment_episode_fallback_get_metadata_attempted: 0,
      enrichment_episode_fallback_get_metadata_skipped: 0,
      enrichment_episode_fallback_get_metadata_failed: 0
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "marks provisional rows ambiguous when recheck strong ids point to a different watchable" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Provisional Conflict",
      base_url: "https://tautulli.provisional-conflict.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Provisional Conflict",
      base_url: "https://radarr.provisional-conflict.local",
      api_key: "secret",
      verify_ssl: true
    )
    provisional_movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_201,
      title: "Conflicting Movie",
      year: 2024,
      metadata_json: {}
    )
    Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_202,
      title: "Different Target",
      year: 2024,
      imdb_id: "tt7202",
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 52, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 52, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Conflicting Movie",
            year: 2024,
            plex_rating_key: "plex-conflict-7201",
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
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-conflict-7201").and_return(
      {
        file_path: nil,
        external_ids: { imdb_id: "tt7202" },
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-provisional-conflict").call

    provisional_movie.reload
    expect(provisional_movie.mapping_status_code).to eq("ambiguous_conflict")
    expect(provisional_movie.mapping_strategy).to eq("conflict_detected")
    expect(provisional_movie.mapping_diagnostics_json["conflict_reason"]).to eq("id_conflicts_with_provisional")
    expect(result).to include(
      provisional_seen: 1,
      provisional_rechecked: 1,
      provisional_promoted: 0,
      provisional_conflicted: 1,
      provisional_still_provisional: 0,
      metadata_recheck_attempted: 1,
      metadata_recheck_failed: 0,
      metadata_recheck_skipped: 0
    )
  end

  it "keeps provisional rows provisional with deterministic counters when recheck is skipped or failed" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Provisional SkipFail",
      base_url: "https://tautulli.provisional-skipfail.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Provisional SkipFail",
      base_url: "https://radarr.provisional-skipfail.local",
      api_key: "secret",
      verify_ssl: true
    )
    skipped_movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_301,
      title: "Skipped Recheck Movie",
      year: 2023,
      metadata_json: {}
    )
    failed_movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_302,
      title: "Failed Recheck Movie",
      year: 2022,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 53, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 53, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Skipped Recheck Movie",
            year: 2023,
            plex_rating_key: nil,
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Failed Recheck Movie",
            year: 2022,
            plex_rating_key: "plex-failed-7302",
            external_ids: {}
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: false,
        next_start: 2
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-failed-7302").and_return(
      {
        file_path: nil,
        external_ids: {},
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-provisional-skip-fail").call

    skipped_movie.reload
    failed_movie.reload
    expect(skipped_movie.mapping_status_code).to eq("provisional_title_year")
    expect(failed_movie.mapping_status_code).to eq("provisional_title_year")
    expect(result).to include(
      provisional_seen: 2,
      provisional_promoted: 0,
      provisional_conflicted: 0,
      provisional_still_provisional: 2,
      metadata_recheck_attempted: 1,
      metadata_recheck_failed: 1,
      metadata_recheck_skipped: 1,
      recheck_eligible_rows: 2
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "handles unresolved success, skipped, and failed branches deterministically" do
    AppSetting.find_or_initialize_by(key: "managed_path_roots").update!(value_json: [ "/mnt/managed" ])

    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Unresolved Matrix",
      base_url: "https://tautulli.unresolved-matrix.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Unresolved Matrix",
      base_url: "https://radarr.unresolved-matrix.local",
      api_key: "secret",
      verify_ssl: true
    )
    resolved_movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_401,
      title: "Resolved by Recheck Movie",
      imdb_id: "tt7401",
      metadata_json: {}
    )
    MediaFile.create!(
      attachable: resolved_movie,
      integration: radarr,
      arr_file_id: 74_001,
      path: "/mnt/managed/movies/resolved-by-recheck.mkv",
      path_canonical: "/mnt/managed/movies/resolved-by-recheck.mkv",
      size_bytes: 1_000,
      quality_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 54, title: "Mixed", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 54, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Unresolved Success",
            year: 2024,
            plex_rating_key: "plex-unresolved-success",
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Unresolved Skip External",
            year: 2024,
            plex_rating_key: nil,
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Unresolved Skip Managed",
            year: 2024,
            file_path: "/mnt/managed/movies/no-arr-match.mkv",
            plex_rating_key: nil,
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Unresolved Failed External",
            year: 2024,
            plex_rating_key: "plex-unresolved-failed",
            external_ids: {}
          }
        ],
        raw_rows_count: 4,
        rows_skipped_invalid: 0,
        records_total: 4,
        has_more: false,
        next_start: 4
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-unresolved-success").and_return(
      {
        file_path: nil,
        external_ids: { imdb_id: "tt7401" },
        provenance: { endpoint: "get_metadata" }
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-unresolved-failed").and_return(
      {
        file_path: nil,
        external_ids: {},
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-unresolved-matrix").call

    resolved_movie.reload
    expect(resolved_movie.mapping_status_code).to eq("verified_external_ids")
    expect(result).to include(
      unresolved_rechecked: 1,
      unresolved_recheck_skipped: 2,
      unresolved_recheck_failed: 1,
      unresolved_reclassified_external: 2,
      unresolved_still_unresolved: 1,
      metadata_recheck_attempted: 2,
      metadata_recheck_failed: 1,
      metadata_recheck_skipped: 2,
      recheck_eligible_rows: 4
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "fails closed on strong-signal disagreement and emits stable tv diagnostics for episode rows" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Strong Conflict",
      base_url: "https://tautulli.strong-conflict.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Strong Conflict",
      base_url: "https://radarr.strong-conflict.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr TV Deferred",
      base_url: "https://sonarr.tv-deferred.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie_by_path = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_501,
      title: "Path Winner Movie",
      metadata_json: {}
    )
    movie_by_id = Movie.create!(
      integration: radarr,
      radarr_movie_id: 7_502,
      title: "ID Winner Movie",
      imdb_id: "tt7502",
      metadata_json: {}
    )
    MediaFile.create!(
      attachable: movie_by_path,
      integration: radarr,
      arr_file_id: 75_001,
      path: "/mnt/movies/strong-conflict.mkv",
      path_canonical: "/mnt/movies/strong-conflict.mkv",
      size_bytes: 1_000,
      quality_json: {}
    )

    series = Series.create!(integration: sonarr, sonarr_series_id: 88_001, title: "Deferred TV Show")
    season = Season.create!(series:, season_number: 2)
    episode = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 88_101,
      episode_number: 4,
      tvdb_id: 88_123,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 55, title: "Mixed", section_type: "mixed" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 55, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            file_path: "/mnt/movies/strong-conflict.mkv",
            plex_rating_key: "plex-strong-conflict",
            external_ids: { imdb_id: "tt7502" }
          },
          {
            media_type: "episode",
            plex_rating_key: "plex-tv-deferred",
            plex_parent_rating_key: "parent-2",
            plex_grandparent_rating_key: "show-1",
            season_number: 2,
            episode_number: 4,
            external_ids: { tvdb_id: 88_123 }
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: false,
        next_start: 2
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-strong-conflict").call

    movie_by_path.reload
    episode.reload
    expect(movie_by_path.mapping_status_code).to eq("ambiguous_conflict")
    expect(movie_by_path.mapping_diagnostics_json["conflict_reason"]).to eq("strong_signal_disagreement")
    expect(episode.mapping_status_code).to eq("verified_external_ids")
    expect(episode.mapping_diagnostics_json.fetch("tv_structure")).to include(
      "outcome" => "unresolved_show_identity",
      "fallback_path" => nil
    )
    expect(episode.mapping_diagnostics_json.dig("tv_structure", "season_episode_keys")).to include(
      "season_number" => 2,
      "episode_number" => 4,
      "parent_rating_key" => "parent-2",
      "grandparent_rating_key" => "show-1"
    )
    expect(result).to include(rows_ambiguous: 1, rows_mapped_by_external_ids: 1)
  end

  it "resolves episodes through show-first structure and keeps episode fallback below baseline" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli TV Show-First Baseline",
      base_url: "https://tautulli.tv-show-first-baseline.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 1 }
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr TV Show-First Baseline",
      base_url: "https://sonarr.tv-show-first-baseline.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 91_000,
      title: "Show-First Baseline",
      tvdb_id: 9_100
    )
    season = Season.create!(series:, season_number: 1)
    episode_one = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 91_101,
      episode_number: 1,
      metadata_json: {}
    )
    episode_two = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 91_102,
      episode_number: 2,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 60, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 60, start: 0, length: 50).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-9101",
            plex_grandparent_rating_key: "plex-show-9100",
            season_number: 1,
            episode_number: 1,
            external_ids: {}
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: true,
        next_start: 1
      }
    )
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 60, start: 1, length: 50).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-9102",
            plex_grandparent_rating_key: "plex-show-9100",
            season_number: 1,
            episode_number: 2,
            external_ids: {}
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: false,
        next_start: 2
      }
    )

    metadata_requests = []
    allow(adapter).to receive(:fetch_metadata) do |rating_key:|
      metadata_requests << rating_key
      if rating_key == "plex-show-9100"
        {
          file_path: nil,
          external_ids: { tvdb_id: 9_100 },
          provenance: { endpoint: "get_metadata" }
        }
      else
        {
          file_path: nil,
          external_ids: {},
          provenance: { endpoint: "get_metadata" }
        }
      end
    end

    result = described_class.new(sync_run:, correlation_id: "corr-library-tv-show-first-baseline").call

    episode_one.reload
    episode_two.reload
    expect(episode_one.mapping_status_code).to eq("verified_tv_structure")
    expect(episode_two.mapping_status_code).to eq("verified_tv_structure")
    expect(episode_one.mapping_strategy).to eq("tv_structure_match")
    expect(episode_two.mapping_strategy).to eq("tv_structure_match")

    baseline_episode_fallback_calls = 2
    actual_episode_fallback_calls = metadata_requests.count { |rating_key| rating_key.start_with?("plex-episode-910") }
    expect(actual_episode_fallback_calls).to eq(0)
    expect(actual_episode_fallback_calls).to be < baseline_episode_fallback_calls
    expect(metadata_requests.count { |rating_key| rating_key == "plex-show-9100" }).to eq(1)

    expect(result).to include(
      recheck_eligible_rows: 2,
      metadata_recheck_attempted: 1,
      metadata_recheck_skipped: 1,
      metadata_recheck_failed: 0,
      unresolved_rechecked: 2,
      status_verified_tv_structure: 2,
      rows_unmapped: 0,
      enrichment_watchable_get_metadata_attempted: 0,
      enrichment_watchable_get_metadata_skipped: 0,
      enrichment_watchable_get_metadata_failed: 0,
      enrichment_show_get_metadata_attempted: 1,
      enrichment_show_get_metadata_skipped: 1,
      enrichment_show_get_metadata_failed: 0,
      enrichment_episode_fallback_get_metadata_attempted: 0,
      enrichment_episode_fallback_get_metadata_skipped: 0,
      enrichment_episode_fallback_get_metadata_failed: 0
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "marks row-level recheck failed when show metadata succeeds but episode fallback is unusable" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli TV Mixed Recheck Failure",
      base_url: "https://tautulli.tv-mixed-recheck-failure.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr TV Mixed Recheck Failure",
      base_url: "https://sonarr.tv-mixed-recheck-failure.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 92_000,
      title: "Mixed Recheck Failure",
      tvdb_id: 9_200
    )
    season = Season.create!(series:, season_number: 1)
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 92_101,
      episode_number: 1,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 61, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 61, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-9209",
            plex_grandparent_rating_key: "plex-show-9200",
            season_number: 9,
            episode_number: 9,
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

    metadata_requests = []
    allow(adapter).to receive(:fetch_metadata) do |rating_key:|
      metadata_requests << rating_key
      case rating_key
      when "plex-show-9200"
        {
          file_path: nil,
          external_ids: { tvdb_id: 9_200 },
          provenance: { endpoint: "get_metadata" }
        }
      when "plex-episode-9209"
        {
          file_path: nil,
          external_ids: {},
          provenance: { endpoint: "get_metadata" }
        }
      else
        nil
      end
    end

    result = described_class.new(sync_run:, correlation_id: "corr-library-tv-mixed-recheck-failure").call

    expect(metadata_requests).to eq([ "plex-show-9200", "plex-episode-9209" ])
    expect(result).to include(
      recheck_eligible_rows: 1,
      metadata_recheck_attempted: 1,
      metadata_recheck_failed: 1,
      metadata_recheck_skipped: 0,
      unresolved_recheck_failed: 1,
      enrichment_watchable_get_metadata_attempted: 0,
      enrichment_watchable_get_metadata_skipped: 0,
      enrichment_watchable_get_metadata_failed: 0,
      enrichment_show_get_metadata_attempted: 1,
      enrichment_show_get_metadata_skipped: 0,
      enrichment_show_get_metadata_failed: 0,
      enrichment_episode_fallback_get_metadata_attempted: 1,
      enrichment_episode_fallback_get_metadata_skipped: 0,
      enrichment_episode_fallback_get_metadata_failed: 1
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "does not emit show-stage counters when show recheck stage is not entered" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Missing Show Key",
      base_url: "https://tautulli.missing-show-key.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Missing Show Key",
      base_url: "https://sonarr.missing-show-key.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(integration: sonarr, sonarr_series_id: 92_100, title: "Missing Show Key")
    season = Season.create!(series:, season_number: 1)
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 92_201,
      episode_number: 9,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 71, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 71, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            season_number: 1,
            episode_number: 9,
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
    allow(adapter).to receive(:fetch_metadata).and_return(nil)

    result = described_class.new(sync_run:, correlation_id: "corr-library-missing-show-key").call

    expect(adapter).not_to have_received(:fetch_metadata)
    expect(result).to include(
      recheck_eligible_rows: 1,
      metadata_recheck_attempted: 0,
      metadata_recheck_skipped: 1,
      metadata_recheck_failed: 0,
      enrichment_watchable_get_metadata_attempted: 0,
      enrichment_watchable_get_metadata_skipped: 0,
      enrichment_watchable_get_metadata_failed: 0,
      enrichment_show_get_metadata_attempted: 0,
      enrichment_show_get_metadata_skipped: 0,
      enrichment_show_get_metadata_failed: 0,
      enrichment_episode_fallback_get_metadata_attempted: 0,
      enrichment_episode_fallback_get_metadata_skipped: 1,
      enrichment_episode_fallback_get_metadata_failed: 0
    )
  end

  it "fails closed with strong_signal_disagreement when path and tv structure resolve different episodes" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Path TV Disagreement",
      base_url: "https://tautulli.path-tv-disagreement.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Path TV Disagreement",
      base_url: "https://sonarr.path-tv-disagreement.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 93_000,
      title: "Path TV Disagreement",
      plex_rating_key: "plex-show-9300"
    )
    season = Season.create!(series:, season_number: 1)
    episode_by_path = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 93_101,
      episode_number: 1,
      metadata_json: {}
    )
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 93_102,
      episode_number: 2,
      metadata_json: {}
    )
    MediaFile.create!(
      attachable: episode_by_path,
      integration: sonarr,
      arr_file_id: 93_001,
      path: "/mnt/tv/path-tv-disagreement-s01e01.mkv",
      path_canonical: "/mnt/tv/path-tv-disagreement-s01e01.mkv",
      size_bytes: 1_000,
      quality_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 62, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 62, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-path-tv-disagreement",
            file_path: "/mnt/tv/path-tv-disagreement-s01e01.mkv",
            plex_grandparent_rating_key: "plex-show-9300",
            season_number: 1,
            episode_number: 2,
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

    result = described_class.new(sync_run:, correlation_id: "corr-library-path-tv-disagreement").call

    episode_by_path.reload
    expect(episode_by_path.mapping_status_code).to eq("ambiguous_conflict")
    expect(episode_by_path.mapping_diagnostics_json["conflict_reason"]).to eq("strong_signal_disagreement")
    expect(result).to include(rows_ambiguous: 1, rows_mapped_by_path: 0, rows_mapped_by_external_ids: 0)
  end

  it "fails closed with strong_signal_disagreement when external ids and tv structure resolve different episodes" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli External TV Disagreement",
      base_url: "https://tautulli.external-tv-disagreement.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr External TV Disagreement",
      base_url: "https://sonarr.external-tv-disagreement.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 94_000,
      title: "External TV Disagreement",
      plex_rating_key: "plex-show-9400"
    )
    season = Season.create!(series:, season_number: 1)
    episode_by_external_id = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 94_101,
      episode_number: 1,
      tvdb_id: 940_001,
      metadata_json: {}
    )
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 94_102,
      episode_number: 2,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 63, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 63, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-external-tv-disagreement",
            plex_grandparent_rating_key: "plex-show-9400",
            season_number: 1,
            episode_number: 2,
            external_ids: { tvdb_id: 940_001 }
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-external-tv-disagreement").call

    episode_by_external_id.reload
    expect(episode_by_external_id.mapping_status_code).to eq("ambiguous_conflict")
    expect(episode_by_external_id.mapping_diagnostics_json["conflict_reason"]).to eq("strong_signal_disagreement")
    expect(result).to include(rows_ambiguous: 1, rows_mapped_by_external_ids: 0)
  end

  it "preserves multiple_external_id_candidates precedence over disagreement when tv structure is also present" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli External Multiples Precedence",
      base_url: "https://tautulli.external-multiples-precedence.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr External Multiples Precedence",
      base_url: "https://sonarr.external-multiples-precedence.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 95_000,
      title: "External Multiples Precedence",
      plex_rating_key: "plex-show-9500"
    )
    season = Season.create!(series:, season_number: 1)
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 95_101,
      episode_number: 1,
      tvdb_id: 950_001,
      metadata_json: {}
    )
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 95_102,
      episode_number: 3,
      tvdb_id: 950_001,
      metadata_json: {}
    )
    tv_structure_episode = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 95_103,
      episode_number: 2,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 64, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 64, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-precedence",
            plex_grandparent_rating_key: "plex-show-9500",
            season_number: 1,
            episode_number: 2,
            external_ids: { tvdb_id: 950_001 }
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 1,
        has_more: false,
        next_start: 1
      }
    )

    described_class.new(sync_run:, correlation_id: "corr-library-external-multiples-precedence").call

    tv_structure_episode.reload
    expect(tv_structure_episode.mapping_status_code).to eq("ambiguous_conflict")
    expect(tv_structure_episode.mapping_diagnostics_json["conflict_reason"]).to eq("multiple_external_id_candidates")
  end

  it "does not fetch show metadata with blank show keys and never uses title/year fallback for tv rows" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Blank Show Key Guard",
      base_url: "https://tautulli.blank-show-key-guard.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Blank Show Key Guard",
      base_url: "https://sonarr.blank-show-key-guard.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(integration: sonarr, sonarr_series_id: 96_000, title: "Blank Show Key Guard")
    season = Season.create!(series:, season_number: 1)
    episode = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 96_101,
      episode_number: 1,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 65, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 65, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            title: "Episode Title Should Not Trigger Movie Fallback",
            year: 2024,
            plex_rating_key: "plex-episode-no-title-year-fallback",
            plex_grandparent_rating_key: "   ",
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

    metadata_requests = []
    allow(adapter).to receive(:fetch_metadata) do |rating_key:|
      metadata_requests << rating_key
      {
        file_path: nil,
        external_ids: {},
        provenance: { endpoint: "get_metadata" }
      }
    end

    result = described_class.new(sync_run:, correlation_id: "corr-library-blank-show-key-guard").call

    episode.reload
    expect(result).to include(rows_mapped_by_title_year: 0)
    expect(episode.mapping_status_code).not_to eq("provisional_title_year")
    expect(metadata_requests).to eq([ "plex-episode-no-title-year-fallback" ])
    expect(metadata_requests).not_to include("")
  end

  it "keeps show metadata cache integration-scoped across the same run" do
    tautulli_one = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Show Cache Scope One",
      base_url: "https://tautulli.show-cache-scope-one.local",
      api_key: "secret",
      verify_ssl: true
    )
    tautulli_two = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Show Cache Scope Two",
      base_url: "https://tautulli.show-cache-scope-two.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Show Cache Scope",
      base_url: "https://sonarr.show-cache-scope.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(
      integration: sonarr,
      sonarr_series_id: 97_000,
      title: "Show Cache Scope",
      tvdb_id: 9_700
    )
    season = Season.create!(series:, season_number: 1)
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 97_101,
      episode_number: 1,
      metadata_json: {}
    )

    health_check_one = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    health_check_two = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli_one, raise_on_unsupported: true).and_return(health_check_one)
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli_two, raise_on_unsupported: true).and_return(health_check_two)

    adapter_one = instance_double(Integrations::TautulliAdapter)
    adapter_two = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_one).and_return(adapter_one)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_two).and_return(adapter_two)

    allow(adapter_one).to receive(:fetch_libraries).and_return([ { library_id: 66, title: "TV", section_type: "show" } ])
    allow(adapter_two).to receive(:fetch_libraries).and_return([ { library_id: 67, title: "TV", section_type: "show" } ])

    allow(adapter_one).to receive(:fetch_library_media_page).with(library_id: 66, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-cache-1",
            plex_grandparent_rating_key: "plex-show-cache-scope",
            season_number: 1,
            episode_number: 1,
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
    allow(adapter_two).to receive(:fetch_library_media_page).with(library_id: 67, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            plex_rating_key: "plex-episode-cache-2",
            plex_grandparent_rating_key: "plex-show-cache-scope",
            season_number: 1,
            episode_number: 1,
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

    show_calls_one = 0
    show_calls_two = 0
    allow(adapter_one).to receive(:fetch_metadata) do |rating_key:|
      show_calls_one += 1 if rating_key == "plex-show-cache-scope"
      {
        file_path: nil,
        external_ids: { tvdb_id: 9_700 },
        provenance: { endpoint: "get_metadata" }
      }
    end
    allow(adapter_two).to receive(:fetch_metadata) do |rating_key:|
      show_calls_two += 1 if rating_key == "plex-show-cache-scope"
      {
        file_path: nil,
        external_ids: { tvdb_id: 9_700 },
        provenance: { endpoint: "get_metadata" }
      }
    end

    result = described_class.new(sync_run:, correlation_id: "corr-library-show-cache-scope").call

    expect(show_calls_one).to eq(1)
    expect(show_calls_two).to eq(1)
    expect(result).to include(recheck_eligible_rows: 2, metadata_recheck_attempted: 2, metadata_recheck_skipped: 0)
  end

  it "emits type_mismatch when path resolves to a different watchable type" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Type Mismatch",
      base_url: "https://tautulli.type-mismatch.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Type Mismatch",
      base_url: "https://sonarr.type-mismatch.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(integration: sonarr, sonarr_series_id: 99_001, title: "Mismatch Show")
    season = Season.create!(series:, season_number: 1)
    episode = Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 99_101,
      episode_number: 1,
      metadata_json: {}
    )
    MediaFile.create!(
      attachable: episode,
      integration: sonarr,
      arr_file_id: 99_001,
      path: "/mnt/tv/type-mismatch-s01e01.mkv",
      path_canonical: "/mnt/tv/type-mismatch-s01e01.mkv",
      size_bytes: 1_000,
      quality_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 56, title: "Mixed", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 56, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            file_path: "/mnt/tv/type-mismatch-s01e01.mkv",
            plex_rating_key: "plex-type-mismatch",
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

    result = described_class.new(sync_run:, correlation_id: "corr-library-type-mismatch").call

    expect(result).to include(rows_ambiguous: 1, status_ambiguous_conflict: 1, watchables_updated: 0)
  end

  it "caches metadata recheck lookups by rating key to avoid duplicate adapter calls" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Recheck Cache",
      base_url: "https://tautulli.recheck-cache.local",
      api_key: "secret",
      verify_ssl: true
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Recheck Cache",
      base_url: "https://radarr.recheck-cache.local",
      api_key: "secret",
      verify_ssl: true
    )
    target_movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 10_001,
      title: "Recheck Cache Target",
      imdb_id: "ttcache10001",
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 57, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 57, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Unresolved Duplicate 1",
            year: 2024,
            plex_rating_key: "plex-shared-cache-key",
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Unresolved Duplicate 2",
            year: 2024,
            plex_rating_key: "plex-shared-cache-key",
            external_ids: {}
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: false,
        next_start: 2
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-shared-cache-key").and_return(
      {
        file_path: nil,
        external_ids: { imdb_id: "ttcache10001" },
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-recheck-cache").call

    target_movie.reload
    expect(target_movie.mapping_status_code).to eq("verified_external_ids")
    expect(adapter).to have_received(:fetch_metadata).with(rating_key: "plex-shared-cache-key").once
    expect(result).to include(
      recheck_eligible_rows: 2,
      metadata_recheck_attempted: 1,
      metadata_recheck_skipped: 1,
      metadata_recheck_failed: 0,
      enrichment_watchable_get_metadata_attempted: 1,
      enrichment_watchable_get_metadata_skipped: 1,
      enrichment_watchable_get_metadata_failed: 0,
      enrichment_show_get_metadata_attempted: 0,
      enrichment_show_get_metadata_skipped: 0,
      enrichment_show_get_metadata_failed: 0,
      enrichment_episode_fallback_get_metadata_attempted: 0,
      enrichment_episode_fallback_get_metadata_skipped: 0,
      enrichment_episode_fallback_get_metadata_failed: 0
    )
  end

  it "reuses metadata recheck cache across pages within an integration run" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Recheck Cross-Page Cache",
      base_url: "https://tautulli.recheck-cross-page-cache.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_history_page_size" => 1 }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Recheck Cross-Page Cache",
      base_url: "https://radarr.recheck-cross-page-cache.local",
      api_key: "secret",
      verify_ssl: true
    )
    Movie.create!(
      integration: radarr,
      radarr_movie_id: 10_101,
      title: "Recheck Cross-Page Target",
      imdb_id: "ttcache10101",
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 59, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 59, start: 0, length: 50).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Cross Page Duplicate 1",
            year: 2024,
            plex_rating_key: "plex-cross-page-cache-key",
            external_ids: {}
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: true,
        next_start: 1
      }
    )
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 59, start: 1, length: 50).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Cross Page Duplicate 2",
            year: 2024,
            plex_rating_key: "plex-cross-page-cache-key",
            external_ids: {}
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: false,
        next_start: 2
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-cross-page-cache-key").and_return(
      {
        file_path: nil,
        external_ids: { imdb_id: "ttcache10101" },
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-recheck-cross-page-cache").call

    expect(adapter).to have_received(:fetch_metadata).with(rating_key: "plex-cross-page-cache-key").once
    expect(result).to include(
      rows_fetched: 2,
      recheck_eligible_rows: 2,
      metadata_recheck_attempted: 1,
      metadata_recheck_skipped: 1,
      metadata_recheck_failed: 0
    )
  end

  it "uses page-level external-id indexing without per-row episode where queries" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli External ID Perf Guard",
      base_url: "https://tautulli.external-id-perf.local",
      api_key: "secret",
      verify_ssl: true
    )
    sonarr = Integration.create!(
      kind: "sonarr",
      name: "Sonarr External ID Perf Guard",
      base_url: "https://sonarr.external-id-perf.local",
      api_key: "secret",
      verify_ssl: true
    )
    series = Series.create!(integration: sonarr, sonarr_series_id: 66_001, title: "Perf Guard Show")
    season = Season.create!(series:, season_number: 1)
    Episode.create!(
      integration: sonarr,
      season: season,
      sonarr_episode_id: 66_101,
      episode_number: 1,
      tvdb_id: 660_001,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).and_return(nil)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 58, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 58, start: 0, length: 500).and_return(
      {
        rows: Array.new(5) do |idx|
          {
            media_type: "episode",
            plex_rating_key: "plex-tvdb-perf-#{idx}",
            external_ids: { tvdb_id: 660_001 }
          }
        end,
        raw_rows_count: 5,
        rows_skipped_invalid: 0,
        records_total: 5,
        has_more: false,
        next_start: 5
      }
    )
    allow(Episode).to receive(:where).and_call_original

    result = described_class.new(sync_run:, correlation_id: "corr-library-external-id-perf").call

    expect(Episode).to have_received(:where).with(tvdb_id: [ 660_001 ]).once
    expect(result).to include(rows_mapped_by_external_ids: 1, rows_ambiguous: 4)
  end

  it "tracks bootstrap and scheduled profile counters and marks empty-library bootstrap complete" do
    tautulli_bootstrap = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Bootstrap Counter",
      base_url: "https://tautulli.bootstrap-counter.local",
      api_key: "secret",
      verify_ssl: true
    )
    tautulli_scheduled = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Scheduled Counter",
      base_url: "https://tautulli.scheduled-counter.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T10:00:00Z"
      }
    )

    health_check_bootstrap = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    health_check_scheduled = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli_bootstrap, raise_on_unsupported: true).and_return(health_check_bootstrap)
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli_scheduled, raise_on_unsupported: true).and_return(health_check_scheduled)

    adapter_bootstrap = instance_double(Integrations::TautulliAdapter, fetch_libraries: [])
    adapter_scheduled = instance_double(Integrations::TautulliAdapter, fetch_libraries: [])
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_bootstrap).and_return(adapter_bootstrap)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_scheduled).and_return(adapter_scheduled)

    result = described_class.new(sync_run:, correlation_id: "corr-library-profile-counters").call

    expect(result).to include(
      profile_bootstrap_integrations: 1,
      profile_scheduled_integrations: 1
    )
    expect(tautulli_bootstrap.reload.settings_json["library_mapping_bootstrap_completed_at"]).to be_present
  end

  it "uses scheduled profile when marker is present regardless of scheduler trigger" do
    scheduler_run = SyncRun.create!(status: "running", trigger: "scheduler")
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Trigger Independence",
      base_url: "https://tautulli.trigger-independence.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T09:00:00Z"
      }
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter, fetch_libraries: [])
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)

    result = described_class.new(sync_run: scheduler_run, correlation_id: "corr-library-trigger-independence").call

    expect(result).to include(profile_bootstrap_integrations: 0, profile_scheduled_integrations: 1)
  end

  it "uses per-integration recheck budgets for scheduled runs" do
    stub_const("#{described_class}::SCHEDULED_METADATA_RECHECK_CALL_BUDGET_PER_INTEGRATION", 1)

    tautulli_one = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Budget Scope One",
      base_url: "https://tautulli.budget-scope-one.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T08:00:00Z"
      }
    )
    tautulli_two = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Budget Scope Two",
      base_url: "https://tautulli.budget-scope-two.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T08:00:00Z"
      }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Budget Scope",
      base_url: "https://radarr.budget-scope.local",
      api_key: "secret",
      verify_ssl: true
    )
    Movie.create!(integration: radarr, radarr_movie_id: 88_101, title: "Budget Scope Movie One", year: 2024, metadata_json: {})
    Movie.create!(integration: radarr, radarr_movie_id: 88_102, title: "Budget Scope Movie Two", year: 2024, metadata_json: {})

    health_check_one = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    health_check_two = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli_one, raise_on_unsupported: true).and_return(health_check_one)
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli_two, raise_on_unsupported: true).and_return(health_check_two)

    adapter_one = instance_double(Integrations::TautulliAdapter)
    adapter_two = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_one).and_return(adapter_one)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_two).and_return(adapter_two)

    allow(adapter_one).to receive(:fetch_libraries).and_return([ { library_id: 81, title: "Movies", section_type: "movie" } ])
    allow(adapter_two).to receive(:fetch_libraries).and_return([ { library_id: 82, title: "Movies", section_type: "movie" } ])
    allow(adapter_one).to receive(:fetch_library_media_page).with(library_id: 81, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Budget Scope Movie One",
            year: 2024,
            plex_rating_key: "plex-budget-scope-1",
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
    allow(adapter_two).to receive(:fetch_library_media_page).with(library_id: 82, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Budget Scope Movie Two",
            year: 2024,
            plex_rating_key: "plex-budget-scope-2",
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
    allow(adapter_one).to receive(:fetch_metadata).with(rating_key: "plex-budget-scope-1").and_return(nil)
    allow(adapter_two).to receive(:fetch_metadata).with(rating_key: "plex-budget-scope-2").and_return(nil)

    result = described_class.new(sync_run:, correlation_id: "corr-library-budget-scope").call

    expect(result).to include(profile_scheduled_integrations: 2, metadata_recheck_attempted: 2)
  end

  it "emits deterministic scheduled-budget skip reason when recheck call budget is exhausted" do
    stub_const("#{described_class}::SCHEDULED_METADATA_RECHECK_CALL_BUDGET_PER_INTEGRATION", 1)

    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Scheduled Budget Skip",
      base_url: "https://tautulli.scheduled-budget-skip.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T11:00:00Z"
      }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Scheduled Budget Skip",
      base_url: "https://radarr.scheduled-budget-skip.local",
      api_key: "secret",
      verify_ssl: true
    )
    Movie.create!(integration: radarr, radarr_movie_id: 89_101, title: "Budget Skip Movie One", year: 2024, metadata_json: {})
    second_movie = Movie.create!(
      integration: radarr,
      radarr_movie_id: 89_102,
      title: "Budget Skip Movie Two",
      year: 2024,
      metadata_json: {}
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 83, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 83, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Budget Skip Movie One",
            year: 2024,
            plex_rating_key: "plex-budget-skip-1",
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Budget Skip Movie Two",
            year: 2024,
            plex_rating_key: "plex-budget-skip-2",
            external_ids: {}
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: false,
        next_start: 2
      }
    )
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-budget-skip-1").and_return(nil)

    result = described_class.new(sync_run:, correlation_id: "corr-library-scheduled-budget-skip").call

    second_movie.reload
    expect(second_movie.mapping_diagnostics_json.dig("recheck", "reason")).to eq("recheck_skipped_scheduled_recheck_budget")
    expect(result).to include(
      recheck_eligible_rows: 2,
      metadata_recheck_attempted: 1,
      metadata_recheck_skipped: 1,
      metadata_recheck_failed: 1,
      enrichment_watchable_get_metadata_attempted: 1,
      enrichment_watchable_get_metadata_skipped: 1,
      enrichment_watchable_get_metadata_failed: 1,
      enrichment_show_get_metadata_attempted: 0,
      enrichment_show_get_metadata_skipped: 0,
      enrichment_show_get_metadata_failed: 0,
      enrichment_episode_fallback_get_metadata_attempted: 0,
      enrichment_episode_fallback_get_metadata_skipped: 0,
      enrichment_episode_fallback_get_metadata_failed: 0
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "orders scheduled rechecks by current-run first-pass status and discovery sequence" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Scheduled Ordering",
      base_url: "https://tautulli.scheduled-ordering.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T11:30:00Z"
      }
    )
    radarr = Integration.create!(
      kind: "radarr",
      name: "Radarr Scheduled Ordering",
      base_url: "https://radarr.scheduled-ordering.local",
      api_key: "secret",
      verify_ssl: true
    )
    Movie.create!(integration: radarr, radarr_movie_id: 90_101, title: "Priority Provisional A", year: 2024, metadata_json: {})
    Movie.create!(integration: radarr, radarr_movie_id: 90_102, title: "Priority Provisional B", year: 2024, metadata_json: {})

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 84, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 84, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Scheduled Unresolved One",
            year: 2024,
            plex_rating_key: "plex-order-unresolved-1",
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Priority Provisional A",
            year: 2024,
            plex_rating_key: "plex-order-provisional-1",
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Scheduled Unresolved Two",
            year: 2024,
            plex_rating_key: "plex-order-unresolved-2",
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Priority Provisional B",
            year: 2024,
            plex_rating_key: "plex-order-provisional-2",
            external_ids: {}
          }
        ],
        raw_rows_count: 4,
        rows_skipped_invalid: 0,
        records_total: 4,
        has_more: false,
        next_start: 4
      }
    )
    metadata_requests = []
    allow(adapter).to receive(:fetch_metadata) do |rating_key:|
      metadata_requests << rating_key
      nil
    end

    result = described_class.new(sync_run:, correlation_id: "corr-library-scheduled-ordering").call

    expect(metadata_requests).to eq(
      [
        "plex-order-provisional-1",
        "plex-order-provisional-2",
        "plex-order-unresolved-1",
        "plex-order-unresolved-2"
      ]
    )
    expect(result).to include(recheck_eligible_rows: 4, metadata_recheck_attempted: 4)
  end

  it "enforces scheduled discovery row budget per integration" do
    stub_const("#{described_class}::SCHEDULED_DISCOVERY_ROW_BUDGET_PER_INTEGRATION", 2)

    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Discovery Budget",
      base_url: "https://tautulli.discovery-budget.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T11:45:00Z"
      }
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 85, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 85, start: 0, length: 2).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Budget Discovery One",
            year: 2024,
            plex_rating_key: nil,
            external_ids: {}
          },
          {
            media_type: "movie",
            title: "Budget Discovery Two",
            year: 2024,
            plex_rating_key: nil,
            external_ids: {}
          }
        ],
        raw_rows_count: 2,
        rows_skipped_invalid: 0,
        records_total: 3,
        has_more: true,
        next_start: 2
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-discovery-budget").call

    expect(adapter).to have_received(:fetch_library_media_page).with(library_id: 85, start: 0, length: 2).once
    expect(result).to include(rows_fetched: 2, rows_processed: 2)
    expect(tautulli.reload.settings_json.dig("library_mapping_state", "libraries", "85", "next_start")).to eq(2)
  end

  it "does not set bootstrap marker when traversal fails before baseline completion" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Bootstrap Failure",
      base_url: "https://tautulli.bootstrap-failure.local",
      api_key: "secret",
      verify_ssl: true
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 86, title: "Movies", section_type: "movie" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 86, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "movie",
            title: "Bootstrap Partial",
            year: 2024,
            plex_rating_key: nil,
            external_ids: {}
          }
        ],
        raw_rows_count: 1,
        rows_skipped_invalid: 0,
        records_total: 2,
        has_more: true,
        next_start: 1
      }
    )
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 86, start: 1, length: 500).and_raise(StandardError, "page read failed")

    expect do
      described_class.new(sync_run:, correlation_id: "corr-library-bootstrap-failure").call
    end.to raise_error(StandardError, "page read failed")

    expect(tautulli.reload.settings_json).not_to have_key("library_mapping_bootstrap_completed_at")
  end

  it "does not count tv fallback budget exhaustion as metadata recheck failure when show lookup already issued a call" do
    stub_const("#{described_class}::SCHEDULED_METADATA_RECHECK_CALL_BUDGET_PER_INTEGRATION", 1)

    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli TV Budget Semantics",
      base_url: "https://tautulli.tv-budget-semantics.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: {
        "library_mapping_bootstrap_completed_at" => "2026-02-14T12:00:00Z"
      }
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    allow(adapter).to receive(:fetch_libraries).and_return([ { library_id: 87, title: "TV", section_type: "show" } ])
    allow(adapter).to receive(:fetch_library_media_page).with(library_id: 87, start: 0, length: 500).and_return(
      {
        rows: [
          {
            media_type: "episode",
            title: "TV Budget Row",
            year: 2024,
            plex_rating_key: "plex-tv-budget-episode",
            plex_grandparent_rating_key: "plex-tv-budget-show",
            season_number: 1,
            episode_number: 2,
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
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-tv-budget-show").and_return(
      {
        file_path: nil,
        external_ids: {},
        provenance: { endpoint: "get_metadata" }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-library-tv-budget-semantics").call

    expect(adapter).to have_received(:fetch_metadata).with(rating_key: "plex-tv-budget-show").once
    expect(adapter).not_to have_received(:fetch_metadata).with(rating_key: "plex-tv-budget-episode")
    expect(result).to include(
      recheck_eligible_rows: 1,
      metadata_recheck_attempted: 1,
      metadata_recheck_skipped: 0,
      metadata_recheck_failed: 0,
      unresolved_recheck_failed: 0,
      unresolved_recheck_skipped: 0
    )
    expect(result[:metadata_recheck_attempted] + result[:metadata_recheck_skipped]).to eq(result[:recheck_eligible_rows])
    expect(result[:metadata_recheck_failed]).to be <= result[:metadata_recheck_attempted]
  end

  it "persists marker and library mapping state in a single integration settings write" do
    tautulli = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Atomic Settings Write",
      base_url: "https://tautulli.atomic-settings.local",
      api_key: "secret",
      verify_ssl: true
    )
    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(tautulli, raise_on_unsupported: true).and_return(health_check)
    adapter = instance_double(Integrations::TautulliAdapter, fetch_libraries: [])
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli).and_return(adapter)
    tautulli_scope = instance_double(ActiveRecord::Relation)
    allow(tautulli_scope).to receive(:find_each).and_yield(tautulli)
    allow(Integration).to receive(:tautulli).and_return(tautulli_scope)

    settings_payloads = []
    allow(tautulli).to receive(:update!).and_wrap_original do |original, *args|
      attrs = args.first
      settings_payloads << attrs[:settings_json] if attrs.is_a?(Hash) && attrs.key?(:settings_json)
      original.call(*args)
    end

    described_class.new(sync_run:, correlation_id: "corr-library-atomic-settings-write").call

    expect(settings_payloads.size).to eq(1)
    expect(settings_payloads.first).to include("library_mapping_state", "library_mapping_bootstrap_completed_at")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ReceiveMessages
