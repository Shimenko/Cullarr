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
      recheck_eligible_rows: 1
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
      "outcome" => "deferred_to_slice_e",
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
      metadata_recheck_failed: 0
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
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ReceiveMessages
