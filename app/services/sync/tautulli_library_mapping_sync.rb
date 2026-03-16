module Sync
  class TautulliLibraryMappingSync
    SCHEDULED_DISCOVERY_ROW_BUDGET_PER_INTEGRATION = 50_000
    SCHEDULED_METADATA_RECHECK_CALL_BUDGET_PER_INTEGRATION = 5_000
    PHASE_PROGRESS_MAPPING_ADVANCE_BATCH_SIZE = 100
    ATTEMPT_ORDER = %w[path external_ids tv_structure title_year].freeze
    RECHECK_ELIGIBLE_STATUSES = %w[provisional_title_year unresolved].freeze

    TV_STRUCTURE_OUTCOME_NON_TV = "not_applicable_non_tv".freeze
    TV_STRUCTURE_OUTCOME_RESOLVED = "resolved_structural_match".freeze
    TV_STRUCTURE_OUTCOME_MISSING_KEYS = "missing_structure_keys".freeze
    TV_STRUCTURE_OUTCOME_UNRESOLVED_SHOW = "unresolved_show_identity".freeze
    TV_STRUCTURE_OUTCOME_UNRESOLVED_EPISODE = "unresolved_episode_position".freeze
    TV_STRUCTURE_OUTCOME_AMBIGUOUS = "ambiguous_structure_match".freeze

    CONFLICT_REASON_ID_CONFLICTS_WITH_PROVISIONAL = "id_conflicts_with_provisional".freeze
    CONFLICT_REASON_MULTIPLE_PATH = "multiple_path_candidates".freeze
    CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS = "multiple_external_id_candidates".freeze
    CONFLICT_REASON_TYPE_MISMATCH = "type_mismatch".freeze
    CONFLICT_REASON_PLEX_RATING_KEY_CONFLICT = "plex_rating_key_conflict".freeze
    CONFLICT_REASON_STRONG_SIGNAL_DISAGREEMENT = "strong_signal_disagreement".freeze

    RECHECK_OUTCOME_NOT_ELIGIBLE = "not_eligible".freeze
    RECHECK_OUTCOME_SUCCESS = "success".freeze
    RECHECK_OUTCOME_SKIPPED = "skipped".freeze
    RECHECK_OUTCOME_FAILED = "failed".freeze
    ENRICHMENT_ENDPOINT_GET_METADATA = "get_metadata".freeze
    ENRICHMENT_SOURCE_CONTEXT_WATCHABLE = "watchable".freeze
    ENRICHMENT_SOURCE_CONTEXT_SHOW = "show".freeze
    ENRICHMENT_SOURCE_CONTEXT_EPISODE_FALLBACK = "episode_fallback".freeze
    ENRICHMENT_OUTCOMES = %w[attempted skipped failed].freeze
    MAPPING_PARALLEL_WORKER_CAP = 8

    def initialize(sync_run:, correlation_id:, phase_progress: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_progress = phase_progress
    end

    def call
      counts = Sync::TautulliLibraryMapping::DiscoveryTraversal.counts_template.merge(
        integrations: 0,
        libraries_fetched: 0
      )

      log_info("sync_phase_worker_started phase=tautulli_library_mapping")
      Integration.tautulli.find_each do |integration|
        telemetry = Sync::TautulliLibraryMapping::Telemetry.new
        integration_started_at = monotonic_now

        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::TautulliAdapter.new(integration:)
        libraries = adapter.fetch_libraries
        counts[:libraries_fetched] += libraries.size
        last_run_telemetry = nil
        mapping_discovery_workers = clamped_mapping_worker_count_for(integration)
        mapping_recheck_workers = clamped_mapping_worker_count_for(integration)

        discovery = Sync::TautulliLibraryMapping::DiscoveryTraversal.new(
          integration: integration,
          adapter: adapter,
          libraries: libraries,
          worker_count: mapping_discovery_workers,
          telemetry: telemetry,
          last_run_telemetry_builder: lambda { |profile:, rows_fetched:, rows_processed:|
            last_run_telemetry = telemetry.last_run_telemetry_payload(
              profile: profile,
              rows_fetched: rows_fetched,
              rows_processed: rows_processed,
              duration_ms: elapsed_ms_since(integration_started_at)
            )
          },
          phase_progress: phase_progress,
          row_processor: lambda { |staged_rows|
            batch_matcher_for(
              integration: integration,
              adapter: adapter,
              profile: discovery.profile,
              worker_count: mapping_recheck_workers,
              telemetry: telemetry
            ).process(staged_rows:)
          }
        )
        integration_counts = discovery.call
        mapping_total_duration_ms = last_run_telemetry.fetch("duration_ms").to_i
        merge_counts!(
          integration_counts,
          telemetry.phase_counts_payload(mapping_total_duration_ms:)
        )
        merge_counts!(counts, integration_counts)

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_library_mapping integration_id=#{integration.id} " \
          "libraries_fetched=#{libraries.size} rows_fetched=#{integration_counts[:rows_fetched]} " \
          "rows_processed=#{integration_counts[:rows_processed]} rows_invalid=#{integration_counts[:rows_invalid]} " \
          "rows_mapped_by_path=#{integration_counts[:rows_mapped_by_path]} " \
          "rows_mapped_by_external_ids=#{integration_counts[:rows_mapped_by_external_ids]} " \
          "rows_mapped_by_title_year=#{integration_counts[:rows_mapped_by_title_year]} " \
          "rows_ambiguous=#{integration_counts[:rows_ambiguous]} rows_unmapped=#{integration_counts[:rows_unmapped]} " \
          "mapping_discovery_workers=#{mapping_discovery_workers} " \
          "mapping_recheck_workers=#{mapping_recheck_workers} " \
          "profile_bootstrap_integrations=#{integration_counts[:profile_bootstrap_integrations]} " \
          "profile_scheduled_integrations=#{integration_counts[:profile_scheduled_integrations]} " \
          "watchables_updated=#{integration_counts[:watchables_updated]} " \
          "watchables_unchanged=#{integration_counts[:watchables_unchanged]} " \
          "state_updates=#{integration_counts[:state_updates]} " \
          "telemetry=#{last_run_telemetry.to_json}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_library_mapping counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :phase_progress, :sync_run

    def batch_matcher_for(integration:, adapter:, profile:, worker_count:, telemetry:)
      @batch_matchers ||= {}
      @batch_matchers.fetch(integration.id) do
        @batch_matchers[integration.id] = Sync::TautulliLibraryMapping::BatchMatcher.new(
          integration: integration,
          adapter: adapter,
          profile: profile,
          worker_count: worker_count,
          telemetry: telemetry,
          phase_progress: phase_progress,
          tv_structure_resolver: Sync::TautulliLibraryMapping::TvStructureResolver.new(telemetry: telemetry),
          diagnostics_and_persistence: Sync::TautulliLibraryMapping::DiagnosticsAndPersistence.new(telemetry: telemetry)
        )
      end
    end

    def merge_counts!(counts, updates)
      updates.each do |key, value|
        counts[key] = counts.fetch(key, 0) + value
      end
    end

    def log_info(message)
      Rails.logger.info(
        [
          message,
          "sync_run_id=#{sync_run.id}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def elapsed_ms_since(started_at)
      ((monotonic_now - started_at) * 1000).round
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def clamped_mapping_worker_count_for(integration)
      [
        integration.tautulli_metadata_workers_resolved,
        MAPPING_PARALLEL_WORKER_CAP
      ].min
    end
  end
end
