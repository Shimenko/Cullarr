module Sync
  module TautulliLibraryMapping
    class MetadataRechecker
      def initialize(
        adapter:,
        integration:,
        profile:,
        telemetry: Sync::TautulliLibraryMapping::Telemetry.new
      )
        @adapter = adapter
        @integration = integration
        @telemetry = telemetry
        @recheck_metadata_cache = {}
        @recheck_show_metadata_cache = {}
        @limited_budget = profile == :scheduled
        @remaining_calls = Sync::TautulliLibraryMappingSync::SCHEDULED_METADATA_RECHECK_CALL_BUDGET_PER_INTEGRATION
      end

      def recheck_outcome_for(
        row:,
        first_evaluation:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
        telemetry.measure_metadata_recheck do
          result = perform_recheck_outcome_for(
            row: row,
            first_evaluation: first_evaluation,
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier,
            context_builder: context_builder,
            context_evaluator: context_evaluator
          )
          telemetry.increment_recheck_budget_exhausted_rows if result[:reason] == "recheck_skipped_scheduled_recheck_budget"
          result
        end
      end

      private

      attr_reader :adapter, :integration, :telemetry

      def perform_recheck_outcome_for(
        row:,
        first_evaluation:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
        initial_status = first_evaluation.fetch(:status_code)
        return { state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_NOT_ELIGIBLE } unless initial_status.in?(Sync::TautulliLibraryMappingSync::RECHECK_ELIGIBLE_STATUSES)

        if row[:media_type].to_s == "episode" && initial_status == "unresolved"
          return tv_episode_recheck_outcome_for(
            row: row,
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier,
            context_builder: context_builder,
            context_evaluator: context_evaluator
          )
        end

        enrichment_events = []
        rating_key = row[:plex_rating_key].to_s.strip.presence
        if rating_key.blank?
          enrichment_events << enrichment_event(
            source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_WATCHABLE,
            endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
            outcome: "skipped"
          )
          return {
            state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: "recheck_skipped_missing_rating_key",
            enrichment_events: enrichment_events
          }
        end

        metadata_result = fetch_recheck_metadata_result(rating_key: rating_key)
        metadata = metadata_result.fetch(:metadata)
        enrichment_events << enrichment_event(
          source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_WATCHABLE,
          endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
          outcome: enrichment_outcome_for(metadata_result:, metadata_present: metadata.present?)
        )
        if metadata_result.fetch(:budget_exhausted, false)
          return {
            state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: "recheck_skipped_scheduled_recheck_budget",
            metadata_call_issued: false,
            enrichment_events: enrichment_events
          }
        end
        if metadata.blank?
          return {
            state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: "recheck_skipped_cached_metadata_unusable",
            metadata_call_issued: false,
            enrichment_events: enrichment_events
          } unless metadata_result.fetch(:call_issued)

          return {
            state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_FAILED,
            reason: "recheck_failed_metadata_lookup",
            metadata_call_issued: true,
            enrichment_events: enrichment_events
          }
        end

        context = context_builder.call(
          row: row,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier,
          metadata: metadata
        )
        evaluation = context_evaluator.call(context)
        {
          state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS,
          metadata_call_issued: metadata_result.fetch(:call_issued),
          enrichment_events: enrichment_events,
          context: context,
          evaluation: evaluation
        }
      end

      def tv_episode_recheck_outcome_for(row:, canonical_mapper:, root_classifier:, context_builder:, context_evaluator:)
        metadata_call_issued = false
        show_context = nil
        show_evaluation = nil
        show_metadata = nil
        enrichment_events = []

        show_rating_key = row[:plex_grandparent_rating_key].to_s.strip.presence
        if show_rating_key.present?
          show_metadata_result = fetch_recheck_show_metadata_result(show_rating_key: show_rating_key)
          show_metadata = show_metadata_result.fetch(:metadata)
          enrichment_events << enrichment_event(
            source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_SHOW,
            endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
            outcome: enrichment_outcome_for(metadata_result: show_metadata_result, metadata_present: show_metadata.present?)
          )
          if show_metadata_result.fetch(:budget_exhausted, false)
            return {
              state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
              reason: "recheck_skipped_scheduled_recheck_budget",
              metadata_call_issued: false,
              enrichment_events: enrichment_events,
              context: show_context,
              evaluation: show_evaluation
            }
          end
          metadata_call_issued ||= show_metadata_result.fetch(:call_issued)

          if show_metadata.present?
            show_context = context_builder.call(
              row: row,
              canonical_mapper: canonical_mapper,
              root_classifier: root_classifier,
              show_metadata: show_metadata
            )
            show_evaluation = context_evaluator.call(show_context)

            if recheck_success_status?(show_evaluation.fetch(:status_code))
              return {
                state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS,
                reason: "recheck_show_metadata_resolved",
                metadata_call_issued: metadata_call_issued,
                enrichment_events: enrichment_events,
                context: show_context,
                evaluation: show_evaluation
              }
            end
          end
        end

        rating_key = row[:plex_rating_key].to_s.strip.presence
        if rating_key.blank?
          enrichment_events << enrichment_event(
            source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_EPISODE_FALLBACK,
            endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
            outcome: "skipped"
          )
          return {
            state: metadata_call_issued ? Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_FAILED : Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: metadata_call_issued ? "recheck_failed_episode_metadata_missing_rating_key" : "recheck_skipped_missing_rating_key",
            metadata_call_issued: metadata_call_issued,
            enrichment_events: enrichment_events,
            context: show_context,
            evaluation: show_evaluation
          }
        end

        metadata_result = fetch_recheck_metadata_result(rating_key: rating_key)
        metadata = metadata_result.fetch(:metadata)
        enrichment_events << enrichment_event(
          source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_EPISODE_FALLBACK,
          endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
          outcome: enrichment_outcome_for(metadata_result:, metadata_present: metadata.present?)
        )
        if metadata_result.fetch(:budget_exhausted, false)
          return {
            state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: "recheck_skipped_scheduled_recheck_budget",
            metadata_call_issued: metadata_call_issued,
            enrichment_events: enrichment_events,
            context: show_context,
            evaluation: show_evaluation
          }
        end
        metadata_call_issued ||= metadata_result.fetch(:call_issued)

        if metadata.blank?
          return {
            state: metadata_call_issued ? Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_FAILED : Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: metadata_result.fetch(:call_issued) ? "recheck_failed_episode_metadata_lookup" : "recheck_skipped_cached_metadata_unusable",
            metadata_call_issued: metadata_call_issued,
            enrichment_events: enrichment_events,
            context: show_context,
            evaluation: show_evaluation
          }
        end

        context = context_builder.call(
          row: row,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier,
          metadata: metadata,
          show_metadata: show_metadata,
          episode_metadata_fallback: true
        )
        evaluation = context_evaluator.call(context)
        {
          state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS,
          reason: "recheck_episode_metadata_fallback",
          metadata_call_issued: metadata_call_issued,
          enrichment_events: enrichment_events,
          context: context,
          evaluation: evaluation
        }
      end

      def fetch_recheck_metadata_result(rating_key:)
        cached = @recheck_metadata_cache[rating_key]
        unless cached.nil?
          telemetry.increment_watchable_metadata_cache_hit
          return {
            metadata: cached == :unusable ? nil : cached,
            call_issued: false,
            budget_exhausted: false
          }
        end
        telemetry.increment_watchable_metadata_cache_miss

        unless consume_recheck_budget_call!
          return {
            metadata: nil,
            call_issued: false,
            budget_exhausted: true
          }
        end

        metadata = adapter.fetch_metadata(rating_key: rating_key)
        if metadata_usable?(metadata)
          @recheck_metadata_cache[rating_key] = metadata
          return { metadata: metadata, call_issued: true, budget_exhausted: false }
        end

        @recheck_metadata_cache[rating_key] = :unusable
        { metadata: nil, call_issued: true, budget_exhausted: false }
      rescue Integrations::Error, Integrations::ContractMismatchError, StandardError
        @recheck_metadata_cache[rating_key] = :unusable
        { metadata: nil, call_issued: true, budget_exhausted: false }
      end

      def fetch_recheck_show_metadata_result(show_rating_key:)
        normalized_key = show_rating_key.to_s.strip.presence
        return { metadata: nil, call_issued: false, budget_exhausted: false } if normalized_key.blank?

        cache_key = [ integration.id, normalized_key ]
        cached = @recheck_show_metadata_cache[cache_key]
        unless cached.nil?
          telemetry.increment_show_metadata_cache_hit
          return {
            metadata: cached == :unusable ? nil : cached,
            call_issued: false,
            budget_exhausted: false
          }
        end
        telemetry.increment_show_metadata_cache_miss

        unless consume_recheck_budget_call!
          return {
            metadata: nil,
            call_issued: false,
            budget_exhausted: true
          }
        end

        metadata = adapter.fetch_metadata(rating_key: normalized_key)
        if metadata_usable_for_show?(metadata)
          @recheck_show_metadata_cache[cache_key] = metadata
          return { metadata: metadata, call_issued: true, budget_exhausted: false }
        end

        @recheck_show_metadata_cache[cache_key] = :unusable
        { metadata: nil, call_issued: true, budget_exhausted: false }
      rescue Integrations::Error, Integrations::ContractMismatchError, StandardError
        @recheck_show_metadata_cache[cache_key] = :unusable
        { metadata: nil, call_issued: true, budget_exhausted: false }
      end

      def consume_recheck_budget_call!
        return true unless @limited_budget
        return false if @remaining_calls <= 0

        @remaining_calls -= 1
        true
      end

      def metadata_usable?(metadata)
        return false unless metadata.is_a?(Hash)

        has_file_paths = Array(metadata[:file_paths]).any? { |path| path.to_s.strip.present? }
        has_file_path = metadata[:file_path].to_s.strip.present?
        has_external_ids = normalized_external_ids(metadata.fetch(:external_ids, {})).any?

        has_file_paths || has_file_path || has_external_ids
      end

      def metadata_usable_for_show?(metadata)
        return false unless metadata.is_a?(Hash)

        normalized_external_ids(metadata.fetch(:external_ids, {})).any?
      end

      def normalized_external_ids(external_ids)
        hash = external_ids.is_a?(Hash) ? external_ids : {}
        imdb_id = hash[:imdb_id].to_s.strip.presence || hash["imdb_id"].to_s.strip.presence
        tmdb_id = integer_or_nil(hash[:tmdb_id] || hash["tmdb_id"])
        tvdb_id = integer_or_nil(hash[:tvdb_id] || hash["tvdb_id"])
        {
          imdb_id: imdb_id,
          tmdb_id: tmdb_id,
          tvdb_id: tvdb_id
        }.compact
      end

      def integer_or_nil(value)
        parsed = Integer(value, exception: false)
        return nil unless parsed&.positive?

        parsed
      end

      def recheck_success_status?(status_code)
        %w[verified_path verified_external_ids verified_tv_structure ambiguous_conflict].include?(status_code)
      end

      def enrichment_event(source_context:, endpoint_context:, outcome:)
        {
          source_context: source_context,
          endpoint_context: endpoint_context,
          outcome: outcome
        }
      end

      def enrichment_outcome_for(metadata_result:, metadata_present:)
        return "skipped" if metadata_result.fetch(:budget_exhausted, false)
        return "attempted" if metadata_present && metadata_result.fetch(:call_issued)
        return "skipped" if metadata_present

        metadata_result.fetch(:call_issued) ? "failed" : "skipped"
      end
    end
  end
end
