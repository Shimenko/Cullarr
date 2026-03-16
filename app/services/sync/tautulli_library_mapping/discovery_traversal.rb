module Sync
  module TautulliLibraryMapping
    class DiscoveryTraversal
      def self.counts_template
        Sync::TautulliLibraryMapping::BatchMatcher.counts_template.merge(
          Sync::TautulliLibraryMapping::Telemetry.phase_counts_template,
          profile_bootstrap_integrations: 0,
          profile_scheduled_integrations: 0,
          rows_fetched: 0,
          rows_invalid: 0,
          state_updates: 0
        )
      end

      attr_reader :profile

      def initialize(
        integration:,
        adapter:,
        libraries:,
        worker_count: 1,
        telemetry: Sync::TautulliLibraryMapping::Telemetry.new,
        last_run_telemetry_builder: nil,
        phase_progress: nil,
        row_processor:
      )
        @integration = integration
        @adapter = adapter
        @libraries = libraries
        @worker_count = worker_count.to_i
        @telemetry = telemetry
        @last_run_telemetry_builder = last_run_telemetry_builder
        @phase_progress = phase_progress
        @row_processor = row_processor
        @profile = mapping_run_profile_for(integration)
      end

      def call
        perform_call
      end

      private

      attr_reader :adapter, :integration, :last_run_telemetry_builder, :libraries, :phase_progress, :row_processor, :telemetry,
                  :worker_count

      def perform_call
        counts = self.class.counts_template
        counts[profile_counter_key_for(profile)] += 1

        state = library_mapping_state_for(integration)
        library_states = state.fetch("libraries")
        persisted_bootstrap_completed_at = integration.settings_json["library_mapping_bootstrap_completed_at"]
        bootstrap_completed_at = persisted_bootstrap_completed_at
        discovery_budget_remaining = if scheduled_profile?(profile)
          Sync::TautulliLibraryMappingSync::SCHEDULED_DISCOVERY_ROW_BUDGET_PER_INTEGRATION
        end
        staged_rows = scheduled_profile?(profile) ? [] : nil
        discovery_sequence = 0
        bootstrap_cycle_completed = bootstrap_profile?(profile)
        state_changed = false

        phase_progress&.add_total!(libraries.size)
        phase_progress&.advance!(libraries.size)

        libraries.each do |library|
          break if scheduled_profile?(profile) && discovery_budget_remaining <= 0

          library_id = library.fetch(:library_id).to_s
          library_state = normalized_library_state(library_states[library_id])
          unless library_supported_for_mapping?(library)
            library_state["next_start"] = 0
            library_state["completed_cycle_count"] += 1
            library_state["last_completed_at"] = Time.current.iso8601
            library_states[library_id] = library_state
            state_changed = true
            next
          end

          start_offset = library_state.fetch("next_start")
          library_cycle_completed = false

          loop do
            break if scheduled_profile?(profile) && discovery_budget_remaining <= 0

            page_length = integration.tautulli_library_mapping_page_size
            if scheduled_profile?(profile)
              page_length = [ page_length, discovery_budget_remaining ].min
            end
            break if page_length <= 0

            discovered_page = discover_page(
              library: library,
              start: start_offset,
              length: page_length,
              discovery_sequence: discovery_sequence,
              staged_rows: staged_rows
            )
            page = discovered_page.fetch(:page)
            fetched_rows = discovered_page.fetch(:fetched_rows)
            discovery_sequence = discovered_page.fetch(:next_discovery_sequence)

            phase_progress&.add_total!(fetched_rows + discovered_page.fetch(:row_count))
            phase_progress&.advance!(fetched_rows)

            counts[:rows_fetched] += fetched_rows
            counts[:rows_invalid] += discovered_page.fetch(:rows_invalid)

            merge_counts!(counts, row_processor.call(discovered_page.fetch(:page_staged_rows))) if bootstrap_profile?(profile)

            discovery_budget_remaining -= fetched_rows if scheduled_profile?(profile)

            if fetched_rows <= 0 || !page.fetch(:has_more)
              library_state["next_start"] = 0
              library_state["completed_cycle_count"] += 1
              library_state["last_completed_at"] = Time.current.iso8601
              state_changed = true
              library_cycle_completed = true
              break
            end

            next_start = page.fetch(:next_start).to_i
            if next_start != library_state["next_start"]
              library_state["next_start"] = next_start
              state_changed = true
            end
            start_offset = next_start
          end

          library_states[library_id] = library_state
          bootstrap_cycle_completed &&= library_cycle_completed
        end

        merge_counts!(counts, row_processor.call(staged_rows)) if scheduled_profile?(profile)

        state["last_run_at"] = Time.current.iso8601
        if last_run_telemetry_builder
          state["last_run_telemetry"] = last_run_telemetry_builder.call(
            profile: profile,
            rows_fetched: counts[:rows_fetched],
            rows_processed: counts[:rows_processed]
          )
        end
        state_changed = true

        bootstrap_completed_at = Time.current.iso8601 if bootstrap_profile?(profile) && bootstrap_cycle_completed

        marker_changed = persisted_bootstrap_completed_at != bootstrap_completed_at
        if state_changed || marker_changed
          persist_library_mapping_settings!(
            integration: integration,
            state: state,
            bootstrap_completed_at: bootstrap_completed_at
          )
          counts[:state_updates] += 1
        end

        counts
      end

      def library_supported_for_mapping?(library)
        !library.fetch(:section_type).to_s.in?(%w[artist])
      end

      def discovery_page_for(library:, start:, length:)
        if library.fetch(:section_type).to_s == "show"
          tv_discovery_page_for(
            library_id: library.fetch(:library_id),
            start: start,
            length: length
          )
        else
          fetch_library_media_page_for_library(
            library_id: library.fetch(:library_id),
            start: start,
            length: length
          )
        end
      end

      def tv_discovery_page_for(library_id:, start:, length:)
        page = fetch_library_media_page_for_library(
          library_id: library_id,
          start: start,
          length: length
        )
        raw_rows_count = page.fetch(:raw_rows_count, 0).to_i
        rows_skipped_invalid = page.fetch(:rows_skipped_invalid, 0).to_i
        row_groups = Array.new(page.fetch(:rows).size)
        direct_rows_emitted = 0
        branch_rows = []
        branch_indexes = []

        page.fetch(:rows).each_with_index do |row, index|
          case row[:media_type].to_s
          when "episode", "movie"
            row_groups[index] = [ row ]
            direct_rows_emitted += 1
          when "show", "season"
            rating_key = row[:plex_rating_key].to_s.strip.presence
            if rating_key.blank?
              rows_skipped_invalid += 1
              next
            end

            branch_rows << row
            branch_indexes << index
          else
            rows_skipped_invalid += 1
          end
        end

        telemetry.increment_discovery_tv_rows_emitted(by: direct_rows_emitted)

        tv_branch_expander_for(length:).expand(root_rows: branch_rows).each_with_index do |result, branch_index|
          row_groups[branch_indexes.fetch(branch_index)] = result.fetch(:rows)
          raw_rows_count += result.fetch(:raw_rows_count)
          rows_skipped_invalid += result.fetch(:rows_skipped_invalid)
          telemetry.increment_discovery_tv_child_page_calls(by: result.fetch(:child_page_calls))
          telemetry.increment_discovery_tv_show_expansions(by: result.fetch(:show_expansions))
          telemetry.increment_discovery_tv_season_expansions(by: result.fetch(:season_expansions))
          telemetry.increment_discovery_tv_rows_emitted(by: result.fetch(:tv_rows_emitted))
        end

        {
          rows: row_groups.compact.flatten(1),
          raw_rows_count: raw_rows_count,
          rows_skipped_invalid: rows_skipped_invalid,
          records_total: page.fetch(:records_total),
          has_more: page.fetch(:has_more),
          next_start: page.fetch(:next_start)
        }
      end

      def discover_page(library:, start:, length:, discovery_sequence:, staged_rows:)
        telemetry.measure_discovery do
          page = discovery_page_for(
            library: library,
            start: start,
            length: length
          )
          page_rows = page.fetch(:rows)
          page_staged_rows = []
          next_discovery_sequence = discovery_sequence

          page_rows.each do |row|
            staged_row = {
              row: row,
              discovery_sequence: next_discovery_sequence
            }
            if scheduled_profile?(profile)
              staged_rows << staged_row
            else
              page_staged_rows << staged_row
            end
            next_discovery_sequence += 1
          end

          {
            page: page,
            page_staged_rows: page_staged_rows,
            fetched_rows: page.fetch(:raw_rows_count, 0).to_i,
            row_count: page_rows.size,
            rows_invalid: page.fetch(:rows_skipped_invalid, 0).to_i,
            next_discovery_sequence: next_discovery_sequence
          }
        end
      end

      def fetch_library_media_page_for_library(library_id:, start:, length:)
        telemetry.increment_discovery_library_page_calls
        adapter.fetch_library_media_page(
          library_id: library_id,
          start: start,
          length: length
        )
      end

      def tv_branch_expander_for(length:)
        @tv_branch_expanders ||= {}
        @tv_branch_expanders.fetch(length) do
          @tv_branch_expanders[length] = Sync::TautulliLibraryMapping::TvBranchExpander.new(
            integration: integration,
            adapter: adapter,
            worker_count: worker_count,
            length: length
          )
        end
      end

      def library_mapping_state_for(integration)
        state = integration.settings_json["library_mapping_state"]
        parsed = state.is_a?(Hash) ? state.deep_dup : {}
        parsed["libraries"] = {} unless parsed["libraries"].is_a?(Hash)
        parsed
      end

      def normalized_library_state(raw_state)
        state = raw_state.is_a?(Hash) ? raw_state.deep_dup : {}
        state["next_start"] = Integer(state["next_start"], exception: false).to_i
        state["completed_cycle_count"] = Integer(state["completed_cycle_count"], exception: false).to_i
        state
      end

      def mapping_run_profile_for(integration)
        marker = integration.settings_json["library_mapping_bootstrap_completed_at"].to_s.strip.presence
        marker.present? ? :scheduled : :bootstrap
      end

      def bootstrap_profile?(profile)
        profile == :bootstrap
      end

      def scheduled_profile?(profile)
        profile == :scheduled
      end

      def profile_counter_key_for(profile)
        bootstrap_profile?(profile) ? :profile_bootstrap_integrations : :profile_scheduled_integrations
      end

      def persist_library_mapping_settings!(integration:, state:, bootstrap_completed_at:)
        settings = integration.settings_json.deep_dup
        settings["library_mapping_state"] = state
        if bootstrap_completed_at.to_s.strip.present?
          settings["library_mapping_bootstrap_completed_at"] = bootstrap_completed_at
        else
          settings.delete("library_mapping_bootstrap_completed_at")
        end
        integration.update!(settings_json: settings)
      end

      def merge_counts!(counts, updates)
        updates.each do |key, value|
          counts[key] = counts.fetch(key, 0) + value
        end
      end
    end
  end
end
