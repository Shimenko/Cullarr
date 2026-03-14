module Sync
  module TautulliLibraryMapping
    class DiscoveryTraversal
      def self.counts_template
        Sync::TautulliLibraryMapping::BatchMatcher.counts_template.merge(
          profile_bootstrap_integrations: 0,
          profile_scheduled_integrations: 0,
          rows_fetched: 0,
          rows_invalid: 0,
          state_updates: 0
        )
      end

      attr_reader :profile

      def initialize(integration:, adapter:, libraries:, phase_progress: nil, row_processor:)
        @integration = integration
        @adapter = adapter
        @libraries = libraries
        @phase_progress = phase_progress
        @row_processor = row_processor
        @profile = mapping_run_profile_for(integration)
      end

      def call
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

            page = discovery_page_for(
              library: library,
              start: start_offset,
              length: page_length
            )
            fetched_rows = page.fetch(:raw_rows_count, 0).to_i
            rows = page.fetch(:rows)

            phase_progress&.add_total!(fetched_rows + rows.size)
            phase_progress&.advance!(fetched_rows)

            counts[:rows_fetched] += fetched_rows
            counts[:rows_invalid] += page.fetch(:rows_skipped_invalid, 0).to_i

            page_staged_rows = []
            rows.each do |row|
              staged_row = {
                row: row,
                discovery_sequence: discovery_sequence
              }
              if scheduled_profile?(profile)
                staged_rows << staged_row
              else
                page_staged_rows << staged_row
              end
              discovery_sequence += 1
            end

            if bootstrap_profile?(profile)
              merge_counts!(counts, row_processor.call(page_staged_rows))
            end

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
        state_changed = true

        if bootstrap_profile?(profile) && bootstrap_cycle_completed
          bootstrap_completed_at = Time.current.iso8601
        end

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

      private

      attr_reader :adapter, :integration, :libraries, :phase_progress, :row_processor

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
          adapter.fetch_library_media_page(
            library_id: library.fetch(:library_id),
            start: start,
            length: length
          )
        end
      end

      def tv_discovery_page_for(library_id:, start:, length:)
        page = adapter.fetch_library_media_page(
          library_id: library_id,
          start: start,
          length: length
        )
        rows = []
        raw_rows_count = page.fetch(:raw_rows_count, 0).to_i
        rows_skipped_invalid = page.fetch(:rows_skipped_invalid, 0).to_i
        traversal_stack = []

        page.fetch(:rows).reverse_each do |row|
          traversal_stack << {
            frame_type: :row,
            row: row,
            depth: 0
          }
        end

        until traversal_stack.empty?
          frame = traversal_stack.pop
          if frame.fetch(:frame_type) == :row
            row = frame.fetch(:row)
            depth = frame.fetch(:depth)
            next if depth > 2

            case row[:media_type].to_s
            when "episode", "movie"
              rows << row
            when "show", "season"
              rating_key = row[:plex_rating_key].to_s.strip.presence
              if rating_key.blank?
                rows_skipped_invalid += 1
                next
              end

              traversal_stack << {
                frame_type: :page,
                rating_key: rating_key,
                start: 0,
                child_depth: depth + 1
              }
            else
              rows_skipped_invalid += 1
            end
            next
          end

          child_page = adapter.fetch_library_media_page(
            rating_key: frame.fetch(:rating_key),
            start: frame.fetch(:start),
            length: length
          )
          raw_rows_count += child_page.fetch(:raw_rows_count, 0).to_i
          rows_skipped_invalid += child_page.fetch(:rows_skipped_invalid, 0).to_i

          if child_page.fetch(:has_more)
            traversal_stack << {
              frame_type: :page,
              rating_key: frame.fetch(:rating_key),
              start: child_page.fetch(:next_start).to_i,
              child_depth: frame.fetch(:child_depth)
            }
          end

          child_page.fetch(:rows).reverse_each do |child_row|
            traversal_stack << {
              frame_type: :row,
              row: child_row,
              depth: frame.fetch(:child_depth)
            }
          end
        end

        {
          rows: rows,
          raw_rows_count: raw_rows_count,
          rows_skipped_invalid: rows_skipped_invalid,
          records_total: page.fetch(:records_total),
          has_more: page.fetch(:has_more),
          next_start: page.fetch(:next_start)
        }
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
