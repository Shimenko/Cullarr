module Sync
  module TautulliLibraryMapping
    class MetadataRechecker
      def initialize(
        adapter:,
        integration:,
        profile:,
        worker_count: 1,
        adapter_factory: nil,
        telemetry: Sync::TautulliLibraryMapping::Telemetry.new
      )
        @adapter = adapter
        @integration = integration
        @telemetry = telemetry
        @worker_count = worker_count.to_i
        @adapter_factory = adapter_factory || -> { Integrations::TautulliAdapter.new(integration: integration) }
        @recheck_metadata_cache = {}
        @recheck_show_metadata_cache = {}
        @limited_budget = profile == :scheduled
        @remaining_calls = Sync::TautulliLibraryMappingSync::SCHEDULED_METADATA_RECHECK_CALL_BUDGET_PER_INTEGRATION
      end

      def recheck_outcomes_for(
        work_items:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
        telemetry.measure_metadata_recheck do
          perform_recheck_outcomes_for(
            work_items: work_items,
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier,
            context_builder: context_builder,
            context_evaluator: context_evaluator
          )
        end
      end

      private

      attr_reader :adapter, :adapter_factory, :integration, :telemetry, :worker_count

      def perform_recheck_outcomes_for(work_items:, canonical_mapper:, root_classifier:, context_builder:, context_evaluator:)
        phase_one_state = reserve_phase_one_fetches(work_items)
        perform_reserved_fetches!(phase_one_state.fetch(:reservations))

        item_states = evaluate_phase_one(
          work_items: work_items,
          phase_one_state: phase_one_state,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier,
          context_builder: context_builder,
          context_evaluator: context_evaluator
        )

        phase_two_state = reserve_phase_two_fetches(item_states)
        perform_reserved_fetches!(phase_two_state.fetch(:reservations))

        item_states.map do |item_state|
          outcome = if item_state[:needs_episode_fallback]
            finish_episode_fallback_outcome(
              item_state: item_state,
              phase_two_state: phase_two_state,
              canonical_mapper: canonical_mapper,
              root_classifier: root_classifier,
              context_builder: context_builder,
              context_evaluator: context_evaluator
            )
          else
            item_state.fetch(:outcome)
          end

          telemetry.increment_recheck_budget_exhausted_rows if outcome[:reason] == "recheck_skipped_scheduled_recheck_budget"
          outcome
        end
      end

      def reserve_phase_one_fetches(work_items)
        state = phase_fetch_state_template

        work_items.each do |work_item|
          row = work_item.fetch(:row)
          first_status = work_item.dig(:first_evaluation, :status_code).to_s
          next unless first_status.in?(Sync::TautulliLibraryMappingSync::RECHECK_ELIGIBLE_STATUSES)

          if row[:media_type].to_s == "episode" && first_status == "unresolved"
            show_rating_key = row[:plex_grandparent_rating_key].to_s.strip.presence
            next if show_rating_key.blank?

            state[:show_fetch_refs][work_item.fetch(:discovery_sequence)] = reserve_fetch_reference(
              state: state,
              cache: @recheck_show_metadata_cache,
              cache_kind: :show,
              cache_key: [ integration.id, show_rating_key ],
              rating_key: show_rating_key
            )
            next
          end

          rating_key = row[:plex_rating_key].to_s.strip.presence
          next if rating_key.blank?

          state[:watchable_fetch_refs][work_item.fetch(:discovery_sequence)] = reserve_fetch_reference(
            state: state,
            cache: @recheck_metadata_cache,
            cache_kind: :watchable,
            cache_key: rating_key,
            rating_key: rating_key
          )
        end

        state
      end

      def evaluate_phase_one(
        work_items:,
        phase_one_state:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
        work_items.map do |work_item|
          row = work_item.fetch(:row)
          first_evaluation = work_item.fetch(:first_evaluation)
          initial_status = first_evaluation.fetch(:status_code)

          item_state = {
            work_item: work_item,
            needs_episode_fallback: false
          }
          unless initial_status.in?(Sync::TautulliLibraryMappingSync::RECHECK_ELIGIBLE_STATUSES)
            item_state[:outcome] = { state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_NOT_ELIGIBLE }
            next item_state
          end

          if row[:media_type].to_s == "episode" && initial_status == "unresolved"
            item_state.merge!(
              evaluate_episode_phase_one(
                work_item: work_item,
                phase_one_state: phase_one_state,
                canonical_mapper: canonical_mapper,
                root_classifier: root_classifier,
                context_builder: context_builder,
                context_evaluator: context_evaluator
              )
            )
            next item_state
          end

          item_state[:outcome] = evaluate_watchable_outcome(
            row: row,
            fetch_reference: phase_one_state.fetch(:watchable_fetch_refs)[work_item.fetch(:discovery_sequence)],
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier,
            context_builder: context_builder,
            context_evaluator: context_evaluator
          )
          item_state
        end
      end

      def evaluate_episode_phase_one(
        work_item:,
        phase_one_state:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
        row = work_item.fetch(:row)
        fetch_reference = phase_one_state.fetch(:show_fetch_refs)[work_item.fetch(:discovery_sequence)]
        metadata_call_issued = false
        show_context = nil
        show_evaluation = nil
        show_metadata = nil
        enrichment_events = []

        if row[:plex_grandparent_rating_key].to_s.strip.present?
          show_metadata_result = resolve_fetch_reference(
            fetch_reference: fetch_reference,
            cache: @recheck_show_metadata_cache
          )
          show_metadata = show_metadata_result.metadata
          enrichment_events << enrichment_event(
            source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_SHOW,
            endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
            outcome: enrichment_outcome_for(metadata_result: show_metadata_result, metadata_present: show_metadata.present?)
          )
          if show_metadata_result.budget_exhausted
            return {
              outcome: {
                state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
                reason: "recheck_skipped_scheduled_recheck_budget",
                metadata_call_issued: false,
                enrichment_events: enrichment_events,
                context: show_context,
                evaluation: show_evaluation
              }
            }
          end

          metadata_call_issued ||= show_metadata_result.call_issued
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
                outcome: {
                  state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS,
                  reason: "recheck_show_metadata_resolved",
                  metadata_call_issued: metadata_call_issued,
                  enrichment_events: enrichment_events,
                  context: show_context,
                  evaluation: show_evaluation
                }
              }
            end
          end
        end

        {
          metadata_call_issued: metadata_call_issued,
          enrichment_events: enrichment_events,
          show_context: show_context,
          show_evaluation: show_evaluation,
          show_metadata: show_metadata,
          needs_episode_fallback: true
        }
      end

      def reserve_phase_two_fetches(item_states)
        state = phase_fetch_state_template

        item_states.each do |item_state|
          next unless item_state[:needs_episode_fallback]

          row = item_state.dig(:work_item, :row)
          rating_key = row[:plex_rating_key].to_s.strip.presence
          next if rating_key.blank?

          state[:watchable_fetch_refs][item_state.dig(:work_item, :discovery_sequence)] = reserve_fetch_reference(
            state: state,
            cache: @recheck_metadata_cache,
            cache_kind: :watchable,
            cache_key: rating_key,
            rating_key: rating_key
          )
        end

        state
      end

      def finish_episode_fallback_outcome(
        item_state:,
        phase_two_state:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
        row = item_state.dig(:work_item, :row)
        metadata_call_issued = item_state.fetch(:metadata_call_issued, false)
        enrichment_events = Array(item_state[:enrichment_events]).dup
        show_context = item_state[:show_context]
        show_evaluation = item_state[:show_evaluation]
        show_metadata = item_state[:show_metadata]

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

        metadata_result = resolve_fetch_reference(
          fetch_reference: phase_two_state.fetch(:watchable_fetch_refs)[item_state.dig(:work_item, :discovery_sequence)],
          cache: @recheck_metadata_cache
        )
        metadata = metadata_result.metadata
        enrichment_events << enrichment_event(
          source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_EPISODE_FALLBACK,
          endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
          outcome: enrichment_outcome_for(metadata_result: metadata_result, metadata_present: metadata.present?)
        )
        if metadata_result.budget_exhausted
          return {
            state: Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: "recheck_skipped_scheduled_recheck_budget",
            metadata_call_issued: metadata_call_issued,
            enrichment_events: enrichment_events,
            context: show_context,
            evaluation: show_evaluation
          }
        end

        metadata_call_issued ||= metadata_result.call_issued
        if metadata.blank?
          return {
            state: metadata_call_issued ? Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_FAILED : Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED,
            reason: metadata_result.call_issued ? "recheck_failed_episode_metadata_lookup" : "recheck_skipped_cached_metadata_unusable",
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

      def evaluate_watchable_outcome(
        row:,
        fetch_reference:,
        canonical_mapper:,
        root_classifier:,
        context_builder:,
        context_evaluator:
      )
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

        metadata_result = resolve_fetch_reference(fetch_reference:, cache: @recheck_metadata_cache)
        metadata = metadata_result.metadata
        enrichment_events << enrichment_event(
          source_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_WATCHABLE,
          endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
          outcome: enrichment_outcome_for(metadata_result: metadata_result, metadata_present: metadata.present?)
        )
        if metadata_result.budget_exhausted
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
          } unless metadata_result.call_issued

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
          metadata_call_issued: metadata_result.call_issued,
          enrichment_events: enrichment_events,
          context: context,
          evaluation: evaluation
        }
      end

      def phase_fetch_state_template
        {
          reservations: [],
          reservation_by_key: {},
          watchable_fetch_refs: {},
          show_fetch_refs: {}
        }
      end

      def reserve_fetch_reference(state:, cache:, cache_kind:, cache_key:, rating_key:)
        cached = cache[cache_key]
        unless cached.nil?
          increment_cache_hit(cache_kind)
          return { type: :cached, cache_key: cache_key }
        end

        existing_reservation = state.fetch(:reservation_by_key)[cache_key]
        if existing_reservation.present?
          increment_cache_hit(cache_kind)
          return { type: :reserved_duplicate, cache_key: cache_key }
        end

        increment_cache_miss(cache_kind)
        unless consume_recheck_budget_call!
          return { type: :budget_exhausted, cache_key: cache_key }
        end

        reservation = {
          cache_key: cache_key,
          cache_kind: cache_kind,
          rating_key: rating_key
        }
        state.fetch(:reservation_by_key)[cache_key] = reservation
        state.fetch(:reservations) << reservation
        { type: :reserved_owner, cache_key: cache_key }
      end

      def resolve_fetch_reference(fetch_reference:, cache:)
        return Sync::TautulliLibraryMapping::MetadataFetchResult.new(metadata: nil, call_issued: false, budget_exhausted: false, missing_key: true) if fetch_reference.nil?

        case fetch_reference.fetch(:type)
        when :budget_exhausted
          Sync::TautulliLibraryMapping::MetadataFetchResult.new(metadata: nil, call_issued: false, budget_exhausted: true, missing_key: false)
        when :cached, :reserved_owner, :reserved_duplicate
          cached = cache[fetch_reference.fetch(:cache_key)]
          Sync::TautulliLibraryMapping::MetadataFetchResult.new(
            metadata: cached == :unusable ? nil : cached,
            call_issued: fetch_reference.fetch(:type) == :reserved_owner,
            budget_exhausted: false,
            missing_key: false
          )
        else
          raise ArgumentError, "unsupported metadata fetch reference: #{fetch_reference.inspect}"
        end
      end

      def perform_reserved_fetches!(reservations)
        return if reservations.empty?

        reservations.each { |reservation| reservation[:fetched_metadata] = fetch_reserved_metadata(reservation) } if serial_fetch_fallback?(reservations)
        parallel_fetch_reserved_metadata!(reservations) unless serial_fetch_fallback?(reservations)

        reservations.each do |reservation|
          cache = reservation.fetch(:cache_kind) == :show ? @recheck_show_metadata_cache : @recheck_metadata_cache
          metadata = reservation.fetch(:fetched_metadata)
          cache[reservation.fetch(:cache_key)] = metadata == :unusable ? :unusable : metadata
        end
      end

      def serial_fetch_fallback?(reservations)
        worker_count <= 1 || reservations.size < 2
      end

      def fetch_reserved_metadata(reservation, adapter: self.adapter)
        metadata = adapter.fetch_metadata(rating_key: reservation.fetch(:rating_key))
        usable = if reservation.fetch(:cache_kind) == :show
          metadata_usable_for_show?(metadata)
        else
          metadata_usable?(metadata)
        end
        usable ? metadata : :unusable
      rescue Integrations::Error, Integrations::ContractMismatchError, StandardError
        :unusable
      end

      def parallel_fetch_reserved_metadata!(reservations)
        work_queue = Queue.new
        reservations.each { |reservation| work_queue << reservation }

        actual_worker_count = [ worker_count, reservations.size ].min
        actual_worker_count.times { work_queue << nil }

        threads = Array.new(actual_worker_count) do
          Thread.new do
            thread_adapter = begin
              adapter_factory.call
            rescue StandardError
              nil
            end

            loop do
              reservation = work_queue.pop
              break if reservation.nil?

              reservation[:fetched_metadata] = if thread_adapter.nil?
                :unusable
              else
                fetch_reserved_metadata(reservation, adapter: thread_adapter)
              end
            end
          end
        end

        threads.each(&:join)
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

      def increment_cache_hit(cache_kind)
        if cache_kind == :show
          telemetry.increment_show_metadata_cache_hit
        else
          telemetry.increment_watchable_metadata_cache_hit
        end
      end

      def increment_cache_miss(cache_kind)
        if cache_kind == :show
          telemetry.increment_show_metadata_cache_miss
        else
          telemetry.increment_watchable_metadata_cache_miss
        end
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
        return "skipped" if metadata_result.budget_exhausted
        return "attempted" if metadata_present && metadata_result.call_issued
        return "skipped" if metadata_present

        metadata_result.call_issued ? "failed" : "skipped"
      end
    end
  end
end
