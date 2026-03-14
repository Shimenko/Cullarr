module Sync
  module TautulliLibraryMapping
    class DiagnosticsAndPersistence
      def mapping_diagnostics_for(row:, first_context:, first_evaluation:, recheck_outcome:, final_resolution:)
        recheck_context = recheck_outcome[:context]
        recheck_evaluation = recheck_outcome[:evaluation]
        tv_structure = recheck_evaluation&.fetch(:tv_structure, nil) || first_evaluation.fetch(:tv_structure)
        diagnostics_path_context = recheck_context || first_context

        {
          version: "v2",
          attempt_order: Sync::TautulliLibraryMappingSync::ATTEMPT_ORDER,
          selected_step: final_resolution[:selected_step],
          conflict_reason: final_resolution[:conflict_reason],
          provenance: {
            discovery: first_context.dig(:provenance, :discovery),
            enrichment: first_context.dig(:provenance, :enrichment),
            show_enrichment: first_context.dig(:provenance, :show_enrichment),
            recheck_enrichment: recheck_context&.dig(:provenance, :enrichment),
            recheck_show_enrichment: recheck_context&.dig(:provenance, :show_enrichment)
          },
          path: {
            raw_path: diagnostics_path_context[:effective_file_path] || first_context[:discovery_file_path],
            discovery_raw_path: first_context[:discovery_file_path],
            raw_paths: diagnostics_path_context[:effective_file_paths],
            normalized_path: diagnostics_path_context[:normalized_path],
            canonical_path: diagnostics_path_context[:canonical_path],
            canonical_paths: diagnostics_path_context[:canonical_paths],
            ownership: diagnostics_path_context[:ownership],
            path_set_ownership: diagnostics_path_context[:path_set_ownership],
            mixed_path_sources: diagnostics_path_context[:mixed_path_sources],
            matched_managed_root: diagnostics_path_context[:matched_managed_root],
            candidate_paths: first_evaluation.dig(:path, :candidate_paths),
            first_pass_candidate_count: first_evaluation.dig(:path, :candidate_count).to_i,
            first_pass_expected_candidate_count: first_evaluation.dig(:path, :expected_candidate_count).to_i,
            recheck_raw_paths: recheck_context&.dig(:effective_file_paths),
            recheck_normalized_path: recheck_context&.dig(:normalized_path),
            recheck_canonical_path: recheck_context&.dig(:canonical_path),
            recheck_canonical_paths: recheck_context&.dig(:canonical_paths),
            recheck_path_set_ownership: recheck_context&.dig(:path_set_ownership),
            recheck_mixed_path_sources: recheck_context&.dig(:mixed_path_sources),
            recheck_candidate_paths: recheck_evaluation&.dig(:path, :candidate_paths),
            recheck_candidate_count: recheck_evaluation&.dig(:path, :candidate_count),
            recheck_expected_candidate_count: recheck_evaluation&.dig(:path, :expected_candidate_count)
          },
          ids: {
            discovery: first_context[:discovery_external_ids],
            first_pass_effective: first_context[:external_ids],
            recheck_effective: recheck_context&.fetch(:external_ids, nil),
            first_pass_candidate_count: first_evaluation.dig(:external_ids, :candidate_count).to_i,
            recheck_candidate_count: recheck_evaluation&.dig(:external_ids, :candidate_count),
            conflict_reason: final_resolution[:conflict_reason]
          },
          tv_structure: tv_structure_diagnostics_payload(tv_structure),
          promotion_conflict: {
            first_pass_status: first_evaluation.fetch(:status_code),
            final_status: final_resolution.fetch(:status_code),
            recheck_outcome: recheck_outcome.fetch(:state),
            recheck_reason: recheck_outcome[:reason],
            conflict_reason: final_resolution[:conflict_reason]
          },
          first_pass: {
            status_code: first_evaluation[:status_code],
            strategy: first_evaluation[:strategy],
            selected_step: first_evaluation[:selected_step],
            conflict_reason: first_evaluation[:conflict_reason]
          },
          recheck: {
            state: recheck_outcome.fetch(:state),
            reason: recheck_outcome[:reason],
            status_code: recheck_evaluation&.fetch(:status_code, nil),
            strategy: recheck_evaluation&.fetch(:strategy, nil),
            selected_step: recheck_evaluation&.fetch(:selected_step, nil),
            conflict_reason: recheck_evaluation&.fetch(:conflict_reason, nil)
          },
          signals: {
            media_type: row[:media_type],
            plex_rating_key: row[:plex_rating_key],
            plex_guid: row[:plex_guid],
            file_path: row[:file_path],
            title: row[:title],
            year: row[:year],
            external_ids: row[:external_ids]
          }.compact
        }
      end

      def persist_resolution!(resolution:, row:, diagnostics:)
        watchable = resolution[:selected_watchable]
        return :unmapped if watchable.blank?

        attrs = {}
        metadata = watchable.metadata_json.is_a?(Hash) ? watchable.metadata_json.deep_dup : {}
        incoming_rating_key = row[:plex_rating_key].to_s.strip.presence
        incoming_guid = row[:plex_guid].to_s.strip.presence

        if incoming_rating_key.present?
          existing_rating_key = watchable.plex_rating_key.to_s.strip.presence
          if existing_rating_key.blank? || resolution[:allow_overwrite_rating_key]
            attrs[:plex_rating_key] = incoming_rating_key
          end
        end

        if incoming_guid.present?
          existing_guid = watchable.plex_guid.to_s.strip.presence
          attrs[:plex_guid] = incoming_guid if existing_guid != incoming_guid
        end

        metadata["plex_added_at"] = row[:plex_added_at] if row[:plex_added_at].present?
        attrs[:metadata_json] = metadata if metadata_changed?(watchable.metadata_json, metadata)
        attrs.merge!(
          watchable.mapping_state_attributes_for(
            status_code: resolution.fetch(:status_code),
            strategy: resolution.fetch(:strategy),
            diagnostics: diagnostics
          )
        )

        persist_watchable_changes!(watchable:, attrs:)
      end

      private

      def tv_structure_diagnostics_payload(tv_structure)
        value = tv_structure.is_a?(Hash) ? tv_structure.deep_dup : {}
        value.delete(:unique_watchable)
        value.delete("unique_watchable")
        value
      end

      def metadata_changed?(current, desired)
        current_hash = current.is_a?(Hash) ? current : {}
        current_hash != desired
      end

      def persist_watchable_changes!(watchable:, attrs:)
        watchable.assign_attributes(attrs)
        return :unchanged unless watchable.changed?

        watchable.save!
        :updated
      end
    end
  end
end
