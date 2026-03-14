module Sync
  module TautulliLibraryMapping
    class BatchMatcher
      def self.enrichment_counter_defaults
        [
          Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_WATCHABLE,
          Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_SHOW,
          Sync::TautulliLibraryMappingSync::ENRICHMENT_SOURCE_CONTEXT_EPISODE_FALLBACK
        ].each_with_object({}) do |source_context, hash|
          Sync::TautulliLibraryMappingSync::ENRICHMENT_OUTCOMES.each do |outcome|
            hash[
              enrichment_counter_key(
                source_context: source_context,
                endpoint_context: Sync::TautulliLibraryMappingSync::ENRICHMENT_ENDPOINT_GET_METADATA,
                outcome: outcome
              )
            ] = 0
          end
        end
      end

      def self.counts_template
        {
          rows_processed: 0,
          rows_mapped_by_path: 0,
          rows_mapped_by_external_ids: 0,
          rows_mapped_by_title_year: 0,
          rows_ambiguous: 0,
          rows_unmapped: 0,
          rows_external_source: 0,
          recheck_eligible_rows: 0,
          metadata_recheck_attempted: 0,
          metadata_recheck_skipped: 0,
          metadata_recheck_failed: 0,
          provisional_seen: 0,
          provisional_rechecked: 0,
          provisional_promoted: 0,
          provisional_conflicted: 0,
          provisional_still_provisional: 0,
          unresolved_rechecked: 0,
          unresolved_recheck_skipped: 0,
          unresolved_recheck_failed: 0,
          unresolved_reclassified_external: 0,
          unresolved_still_unresolved: 0,
          status_verified_path: 0,
          status_verified_external_ids: 0,
          status_verified_tv_structure: 0,
          status_provisional_title_year: 0,
          status_external_source_not_managed: 0,
          status_unresolved: 0,
          status_ambiguous_conflict: 0,
          watchables_updated: 0,
          watchables_unchanged: 0
        }.merge(enrichment_counter_defaults)
      end

      def self.enrichment_counter_key(source_context:, endpoint_context:, outcome:)
        "enrichment_#{source_context}_#{endpoint_context}_#{outcome}".to_sym
      end

      def initialize(
        integration:,
        adapter:,
        profile:,
        telemetry: Sync::TautulliLibraryMapping::Telemetry.new,
        phase_progress: nil,
        tv_structure_resolver:,
        diagnostics_and_persistence:
      )
        @integration = integration
        @profile = profile
        @telemetry = telemetry
        @phase_progress = phase_progress
        @tv_structure_resolver = tv_structure_resolver
        @diagnostics_and_persistence = diagnostics_and_persistence
        @metadata_rechecker = Sync::TautulliLibraryMapping::MetadataRechecker.new(
          adapter: adapter,
          integration: integration,
          profile: profile,
          telemetry: telemetry
        )
      end

      def process(staged_rows:)
        counts = self.class.counts_template
        return counts if staged_rows.blank?

        canonical_mapper = Sync::CanonicalPathMapper.new(integration: integration)
        root_classifier = Paths::ManagedRootClassifier.new(
          managed_path_roots: AppSetting.db_value_for("managed_path_roots")
        )
        rows = staged_rows.map { |entry| entry.fetch(:row) }
        @path_lookup = build_path_lookup(rows:, canonical_mapper:)
        @movie_match_index = build_movie_match_index(rows:)
        @episode_match_index = build_episode_match_index(rows:)
        @movie_title_year_match_index = build_movie_title_year_match_index(rows:)

        work_items = staged_rows.sort_by { |entry| entry.fetch(:discovery_sequence) }.map do |entry|
          row = entry.fetch(:row)
          first_context = row_context_for(
            row: row,
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier
          )
          first_evaluation = evaluate_context(context: first_context)
          {
            row: row,
            discovery_sequence: entry.fetch(:discovery_sequence),
            first_context: first_context,
            first_evaluation: first_evaluation
          }
        end

        pending_progress_rows = 0
        ordered_work_items_for(work_items:).each do |work_item|
          row = work_item.fetch(:row)
          first_context = work_item.fetch(:first_context)
          first_evaluation = work_item.fetch(:first_evaluation)

          counts[:rows_processed] += 1
          outcome = metadata_rechecker.recheck_outcome_for(
            row: row,
            first_evaluation: first_evaluation,
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier,
            context_builder: method(:row_context_for),
            context_evaluator: ->(context) { evaluate_context(context: context) }
          )

          increment_recheck_counters!(counts:, first_status: first_evaluation.fetch(:status_code), outcome:)

          final_resolution = final_resolution_for(
            first_context: first_context,
            first_evaluation: first_evaluation,
            recheck_outcome: outcome
          )
          final_resolution = apply_plex_rating_key_conflict_rule(
            resolution: final_resolution,
            row: row
          )

          diagnostics = diagnostics_and_persistence.mapping_diagnostics_for(
            row: row,
            first_context: first_context,
            first_evaluation: first_evaluation,
            recheck_outcome: outcome,
            final_resolution: final_resolution
          )
          increment_transition_counters!(
            counts: counts,
            first_status: first_evaluation.fetch(:status_code),
            final_status: final_resolution.fetch(:status_code)
          )

          status_code = final_resolution.fetch(:status_code)
          counts[status_counter_key_for(status_code)] += 1

          case status_code
          when "verified_path"
            counts[:rows_mapped_by_path] += 1
          when "verified_external_ids"
            counts[:rows_mapped_by_external_ids] += 1
          when "verified_tv_structure"
            # TV structure is a verified mapping outcome and must never be counted as unmapped.
          when "provisional_title_year"
            counts[:rows_mapped_by_title_year] += 1
          when "ambiguous_conflict"
            counts[:rows_ambiguous] += 1
          when "external_source_not_managed"
            counts[:rows_external_source] += 1
            counts[:rows_unmapped] += 1
          else
            counts[:rows_unmapped] += 1
          end

          persistence = diagnostics_and_persistence.persist_resolution!(
            resolution: final_resolution,
            row: row,
            diagnostics: diagnostics
          )
          if persistence == :updated
            counts[:watchables_updated] += 1
          elsif persistence == :unchanged
            counts[:watchables_unchanged] += 1
          end

          pending_progress_rows += 1
          next unless pending_progress_rows >= Sync::TautulliLibraryMappingSync::PHASE_PROGRESS_MAPPING_ADVANCE_BATCH_SIZE

          phase_progress&.advance!(pending_progress_rows)
          pending_progress_rows = 0
        end

        phase_progress&.advance!(pending_progress_rows) if pending_progress_rows.positive?

        if counts[:metadata_recheck_attempted] + counts[:metadata_recheck_skipped] != counts[:recheck_eligible_rows]
          raise "library mapping metadata recheck invariant violated: attempted + skipped must equal eligible"
        end
        if counts[:metadata_recheck_failed] > counts[:metadata_recheck_attempted]
          raise "library mapping metadata recheck invariant violated: failed must be <= attempted"
        end

        counts
      end

      private

      attr_reader :diagnostics_and_persistence, :integration, :metadata_rechecker, :phase_progress, :profile, :telemetry,
                  :tv_structure_resolver

      def build_path_lookup(rows:, canonical_mapper:)
        paths = rows.filter_map do |row|
          canonical_path_for(
            raw_path: row[:file_path],
            canonical_mapper: canonical_mapper
          )
        end.uniq
        return {} if paths.empty?

        media_rows = MediaFile.where(path_canonical: paths)
                             .pluck(:path_canonical, :attachable_type, :attachable_id)
        movie_ids = media_rows.filter_map { |(_, type, id)| type == "Movie" ? id : nil }
        episode_ids = media_rows.filter_map { |(_, type, id)| type == "Episode" ? id : nil }
        movies_by_id = Movie.where(id: movie_ids).index_by(&:id)
        episodes_by_id = Episode.where(id: episode_ids).index_by(&:id)

        grouped = Hash.new { |hash, key| hash[key] = [] }
        media_rows.each do |(path, attachable_type, attachable_id)|
          watchable = if attachable_type == "Movie"
            movies_by_id[attachable_id]
          elsif attachable_type == "Episode"
            episodes_by_id[attachable_id]
          end
          next if watchable.blank?

          grouped[path] << watchable
        end

        grouped.transform_values { |watchables| watchables.uniq { |watchable| [ watchable.class.name, watchable.id ] } }
      end

      def build_movie_match_index(rows:)
        movie_rows = rows.select { |row| row[:media_type] == "movie" }
        imdb_ids = movie_rows.filter_map { |row| row.dig(:external_ids, :imdb_id).to_s.presence }.uniq
        tmdb_ids = movie_rows.filter_map { |row| row.dig(:external_ids, :tmdb_id) }.uniq
        return { by_imdb_id: {}, by_tmdb_id: {} } if imdb_ids.empty? && tmdb_ids.empty?

        candidates = Movie.none
        candidates = candidates.or(Movie.where(imdb_id: imdb_ids)) if imdb_ids.any?
        candidates = candidates.or(Movie.where(tmdb_id: tmdb_ids)) if tmdb_ids.any?
        candidate_rows = candidates.to_a

        {
          by_imdb_id: candidate_rows.group_by(&:imdb_id),
          by_tmdb_id: candidate_rows.group_by(&:tmdb_id)
        }
      end

      def build_episode_match_index(rows:)
        episode_rows = rows.select { |row| row[:media_type] == "episode" }
        imdb_ids = episode_rows.filter_map { |row| row.dig(:external_ids, :imdb_id).to_s.presence }.uniq
        tmdb_ids = episode_rows.filter_map { |row| row.dig(:external_ids, :tmdb_id) }.uniq
        tvdb_ids = episode_rows.filter_map { |row| row.dig(:external_ids, :tvdb_id) }.uniq
        return { by_imdb_id: {}, by_tmdb_id: {}, by_tvdb_id: {} } if imdb_ids.empty? && tmdb_ids.empty? && tvdb_ids.empty?

        candidates = Episode.none
        candidates = candidates.or(Episode.where(imdb_id: imdb_ids)) if imdb_ids.any?
        candidates = candidates.or(Episode.where(tmdb_id: tmdb_ids)) if tmdb_ids.any?
        candidates = candidates.or(Episode.where(tvdb_id: tvdb_ids)) if tvdb_ids.any?
        candidate_rows = candidates.to_a

        {
          by_imdb_id: candidate_rows.group_by(&:imdb_id),
          by_tmdb_id: candidate_rows.group_by(&:tmdb_id),
          by_tvdb_id: candidate_rows.group_by(&:tvdb_id)
        }
      end

      def build_movie_title_year_match_index(rows:)
        movie_rows = rows.select { |row| row[:media_type] == "movie" }
        keys = movie_rows.filter_map do |row|
          normalized_title = normalized_title_for_match(row[:title])
          next if normalized_title.blank?

          [ normalized_title, normalized_year_for_match(row[:year]) ]
        end.uniq
        return {} if keys.empty?

        titles = keys.map(&:first).uniq
        candidates = Movie.where("LOWER(title) IN (?)", titles).to_a

        grouped = Hash.new { |hash, key| hash[key] = [] }
        candidates.each do |movie|
          grouped[
            [
              normalized_title_for_match(movie.title),
              normalized_year_for_match(movie.year)
            ]
          ] << movie
        end
        grouped.transform_values { |movies| movies.uniq(&:id) }
      end

      def row_context_for(
        row:,
        canonical_mapper:,
        root_classifier:,
        metadata: nil,
        show_metadata: nil,
        episode_metadata_fallback: false
      )
        discovery_external_ids = normalized_external_ids(row.fetch(:external_ids, {}))
        metadata_external_ids = normalized_external_ids(metadata&.fetch(:external_ids, {}))
        show_external_ids = normalized_external_ids(show_metadata&.fetch(:external_ids, {}))
        effective_external_ids = discovery_external_ids.merge(metadata_external_ids.compact)
        effective_file_paths = effective_file_paths_for(row:, metadata:)
        path_candidates = path_candidates_for(
          raw_paths: effective_file_paths,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier
        )
        selected_path_candidate = selected_path_candidate_for(path_candidates: path_candidates)
        file_path = selected_path_candidate&.fetch(:raw_path, nil) || effective_file_paths.first

        {
          media_type: row[:media_type].to_s,
          title: row[:title],
          year: row[:year],
          plex_rating_key: row[:plex_rating_key].to_s.strip.presence,
          plex_guid: row[:plex_guid].to_s.strip.presence,
          plex_parent_rating_key: row[:plex_parent_rating_key].to_s.strip.presence,
          plex_grandparent_rating_key: row[:plex_grandparent_rating_key].to_s.strip.presence,
          season_number: integer_or_nil(row[:season_number]),
          episode_number: integer_or_nil(row[:episode_number]),
          discovery_file_path: row[:file_path],
          effective_file_path: file_path,
          effective_file_paths: effective_file_paths,
          canonical_path: selected_path_candidate&.fetch(:canonical_path, nil),
          canonical_paths: path_candidates.map { |candidate| candidate.fetch(:canonical_path) }.uniq,
          ownership: selected_path_candidate&.fetch(:ownership, nil),
          path_set_ownership: path_set_ownership_for(path_candidates: path_candidates),
          mixed_path_sources: mixed_path_sources?(path_candidates: path_candidates),
          has_managed_path_candidate: path_candidates.any? { |candidate| candidate[:ownership] == "managed" },
          has_external_path_candidate: path_candidates.any? { |candidate| candidate[:ownership] == "external" },
          matched_managed_root: selected_path_candidate&.fetch(:matched_managed_root, nil),
          normalized_path: selected_path_candidate&.fetch(:normalized_path, nil),
          path_candidates: path_candidates,
          external_ids: effective_external_ids,
          discovery_external_ids: discovery_external_ids,
          metadata_external_ids: metadata_external_ids,
          show_external_ids: show_external_ids,
          tv_episode_metadata_fallback: episode_metadata_fallback,
          provenance: {
            discovery: row[:provenance],
            enrichment: metadata&.fetch(:provenance, nil),
            show_enrichment: show_metadata&.fetch(:provenance, nil)
          }
        }
      end

      def evaluate_context(context:)
        path_result = resolve_path_candidates(context)
        external_ids_result = resolve_external_id_candidates(context)
        title_year_result = resolve_title_year_candidates(context)
        tv_structure_result = tv_structure_resolver.resolve_tv_structure_candidates(
          context: context,
          integration: integration
        )

        conflict_reason = strong_conflict_reason_for(
          context: context,
          path_result: path_result,
          external_ids_result: external_ids_result,
          tv_structure_result: tv_structure_result
        )

        selected_step, selected_watchable = selected_step_for(
          path_result: path_result,
          external_ids_result: external_ids_result,
          tv_structure_result: tv_structure_result,
          title_year_result: title_year_result
        )

        if conflict_reason.present?
          return {
            status_code: "ambiguous_conflict",
            strategy: "conflict_detected",
            selected_step: selected_step,
            selected_watchable: selected_watchable,
            conflict_reason: conflict_reason,
            path: path_result,
            external_ids: external_ids_result,
            title_year: title_year_result,
            tv_structure: tv_structure_result
          }
        end

        case selected_step
        when "path"
          {
            status_code: "verified_path",
            strategy: "path_match",
            selected_step: "path",
            selected_watchable: selected_watchable,
            conflict_reason: nil,
            path: path_result,
            external_ids: external_ids_result,
            title_year: title_year_result,
            tv_structure: tv_structure_result
          }
        when "external_ids"
          {
            status_code: "verified_external_ids",
            strategy: "external_ids_match",
            selected_step: "external_ids",
            selected_watchable: selected_watchable,
            conflict_reason: nil,
            path: path_result,
            external_ids: external_ids_result,
            title_year: title_year_result,
            tv_structure: tv_structure_result
          }
        when "tv_structure"
          {
            status_code: "verified_tv_structure",
            strategy: "tv_structure_match",
            selected_step: "tv_structure",
            selected_watchable: selected_watchable,
            conflict_reason: nil,
            path: path_result,
            external_ids: external_ids_result,
            title_year: title_year_result,
            tv_structure: tv_structure_result
          }
        when "title_year"
          {
            status_code: "provisional_title_year",
            strategy: "title_year_fallback",
            selected_step: "title_year",
            selected_watchable: selected_watchable,
            conflict_reason: nil,
            path: path_result,
            external_ids: external_ids_result,
            title_year: title_year_result,
            tv_structure: tv_structure_result
          }
        else
          {
            status_code: "unresolved",
            strategy: "no_match",
            selected_step: nil,
            selected_watchable: nil,
            conflict_reason: nil,
            path: path_result,
            external_ids: external_ids_result,
            title_year: title_year_result,
            tv_structure: tv_structure_result
          }
        end
      end

      def resolve_path_candidates(context)
        path_candidates = Array(context.fetch(:path_candidates, []))
        return empty_path_result if path_candidates.empty?

        expected_type = context.fetch(:media_type) == "movie" ? Movie : Episode
        candidate_results = path_candidates.map do |path_candidate|
          canonical_path = path_candidate.fetch(:canonical_path)
          matches = @path_lookup.fetch(canonical_path) do
            fetched = watchables_for_canonical_path(canonical_path)
            @path_lookup[canonical_path] = fetched
          end
          expected_matches = matches.select { |watchable| watchable.is_a?(expected_type) }

          {
            raw_path: path_candidate.fetch(:raw_path),
            canonical_path: canonical_path,
            normalized_path: path_candidate.fetch(:normalized_path),
            ownership: path_candidate.fetch(:ownership),
            matched_managed_root: path_candidate.fetch(:matched_managed_root),
            candidate_count: matches.size,
            expected_candidate_count: expected_matches.size,
            mismatch_present: expected_matches.empty? && matches.any?,
            watchables: matches,
            expected_watchables: expected_matches
          }
        end
        unique_matches = unique_watchables(candidate_results.flat_map { |result| result.fetch(:watchables) })
        expected_unique_matches = unique_watchables(candidate_results.flat_map { |result| result.fetch(:expected_watchables) })
        unique = expected_unique_matches.one? ? expected_unique_matches.first : nil
        matched_path = if unique.present?
          candidate_results.find do |result|
            result.fetch(:expected_watchables).any? { |watchable| same_watchable?(watchable, unique) }
          end
        else
          candidate_results.find { |result| result.fetch(:expected_candidate_count).positive? } ||
            candidate_results.find { |result| result.fetch(:candidate_count).positive? }
        end

        {
          canonical_path: matched_path&.fetch(:canonical_path, nil) || context.fetch(:canonical_path),
          candidate_count: unique_matches.size,
          expected_candidate_count: expected_unique_matches.size,
          unique_watchable: unique,
          mismatch_present: candidate_results.any? { |result| result.fetch(:mismatch_present) },
          candidate_paths: candidate_results.map do |result|
            {
              raw_path: result.fetch(:raw_path),
              canonical_path: result.fetch(:canonical_path),
              normalized_path: result.fetch(:normalized_path),
              ownership: result.fetch(:ownership),
              matched_managed_root: result.fetch(:matched_managed_root),
              candidate_count: result.fetch(:candidate_count),
              expected_candidate_count: result.fetch(:expected_candidate_count),
              mismatch_present: result.fetch(:mismatch_present)
            }
          end
        }
      end

      def resolve_external_id_candidates(context)
        external_ids = context.fetch(:external_ids)
        return empty_external_result if external_ids.blank?

        matches = if context.fetch(:media_type) == "movie"
          movie_matches_for_external_ids(external_ids: external_ids)
        else
          episode_matches_for_external_ids(external_ids: external_ids)
        end
        unique = matches.one? ? matches.first : nil

        {
          candidate_count: matches.size,
          unique_watchable: unique,
          external_ids: external_ids
        }
      end

      def watchables_for_canonical_path(canonical_path)
        media_rows = MediaFile.where(path_canonical: canonical_path)
                             .pluck(:attachable_type, :attachable_id)
        return [] if media_rows.empty?

        movie_ids = media_rows.filter_map { |(type, id)| type == "Movie" ? id : nil }
        episode_ids = media_rows.filter_map { |(type, id)| type == "Episode" ? id : nil }
        movies_by_id = Movie.where(id: movie_ids).index_by(&:id)
        episodes_by_id = Episode.where(id: episode_ids).index_by(&:id)

        media_rows.filter_map do |(attachable_type, attachable_id)|
          attachable_type == "Movie" ? movies_by_id[attachable_id] : episodes_by_id[attachable_id]
        end.uniq { |watchable| [ watchable.class.name, watchable.id ] }
      end

      def resolve_title_year_candidates(context)
        return empty_title_year_result unless context.fetch(:media_type) == "movie"

        normalized_title = normalized_title_for_match(context.fetch(:title))
        return empty_title_year_result if normalized_title.blank?

        key = [ normalized_title, normalized_year_for_match(context.fetch(:year)) ]
        matches = @movie_title_year_match_index[key] || []
        unique = matches.one? ? matches.first : nil

        {
          candidate_count: matches.size,
          unique_watchable: unique,
          key: key
        }
      end

      def selected_step_for(path_result:, external_ids_result:, tv_structure_result:, title_year_result:)
        return [ "path", path_result.fetch(:unique_watchable) ] if path_result[:unique_watchable].present?
        return [ "external_ids", external_ids_result.fetch(:unique_watchable) ] if external_ids_result[:unique_watchable].present?
        return [ "tv_structure", tv_structure_result.fetch(:unique_watchable) ] if tv_structure_result[:unique_watchable].present?
        return [ "title_year", title_year_result.fetch(:unique_watchable) ] if title_year_result[:unique_watchable].present?

        [ nil, nil ]
      end

      def strong_conflict_reason_for(context:, path_result:, external_ids_result:, tv_structure_result:)
        return Sync::TautulliLibraryMappingSync::CONFLICT_REASON_MULTIPLE_PATH if path_result.fetch(:expected_candidate_count) > 1
        return Sync::TautulliLibraryMappingSync::CONFLICT_REASON_MULTIPLE_PATH if path_result.fetch(:candidate_count) > 1
        return Sync::TautulliLibraryMappingSync::CONFLICT_REASON_TYPE_MISMATCH if path_result.fetch(:mismatch_present)
        return Sync::TautulliLibraryMappingSync::CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS if external_ids_result.fetch(:candidate_count) > 1
        return tv_structure_result.fetch(:conflict_reason) if tv_structure_result.fetch(:conflict_reason).present?

        path_watchable = path_result.fetch(:unique_watchable)
        external_ids_watchable = external_ids_result.fetch(:unique_watchable)
        tv_structure_watchable = tv_structure_result.fetch(:unique_watchable)
        strong_unique_watchables = [
          path_watchable,
          external_ids_watchable,
          tv_structure_watchable
        ].compact

        if strong_unique_watchables.uniq { |watchable| [ watchable.class.name, watchable.id ] }.size > 1
          return Sync::TautulliLibraryMappingSync::CONFLICT_REASON_STRONG_SIGNAL_DISAGREEMENT
        end

        selected = strong_unique_watchables.first
        if selected.present? && !watchable_type_matches_media_type?(watchable: selected, media_type: context.fetch(:media_type))
          return Sync::TautulliLibraryMappingSync::CONFLICT_REASON_TYPE_MISMATCH
        end

        nil
      end

      def final_resolution_for(first_context:, first_evaluation:, recheck_outcome:)
        first_status = first_evaluation.fetch(:status_code)
        recheck_state = recheck_outcome.fetch(:state)
        recheck_evaluation = recheck_outcome[:evaluation]
        recheck_context = recheck_outcome[:context]

        case first_status
        when "ambiguous_conflict", "verified_path", "verified_external_ids", "verified_tv_structure"
          resolution_from_evaluation(first_evaluation)
        when "provisional_title_year"
          provisional_resolution_for(
            first_evaluation: first_evaluation,
            recheck_state: recheck_state,
            recheck_evaluation: recheck_evaluation
          )
        when "unresolved"
          unresolved_resolution_for(
            first_context: first_context,
            first_evaluation: first_evaluation,
            recheck_state: recheck_state,
            recheck_context: recheck_context,
            recheck_evaluation: recheck_evaluation
          )
        else
          resolution_from_evaluation(first_evaluation)
        end
      end

      def provisional_resolution_for(first_evaluation:, recheck_state:, recheck_evaluation:)
        provisional_watchable = first_evaluation.fetch(:selected_watchable)
        if recheck_state == Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS && recheck_evaluation.present?
          recheck_status = recheck_evaluation.fetch(:status_code)
          if recheck_status == "ambiguous_conflict"
            return resolution_from_evaluation(
              recheck_evaluation.merge(
                selected_watchable: provisional_watchable || recheck_evaluation[:selected_watchable]
              )
            )
          end
          if %w[verified_path verified_external_ids].include?(recheck_status)
            recheck_watchable = recheck_evaluation.fetch(:selected_watchable)
            if same_watchable?(provisional_watchable, recheck_watchable)
              return resolution_from_evaluation(recheck_evaluation.merge(selected_watchable: provisional_watchable))
            end

            return {
              status_code: "ambiguous_conflict",
              strategy: "conflict_detected",
              selected_step: recheck_evaluation[:selected_step],
              selected_watchable: provisional_watchable,
              conflict_reason: Sync::TautulliLibraryMappingSync::CONFLICT_REASON_ID_CONFLICTS_WITH_PROVISIONAL
            }
          end
        end

        {
          status_code: "provisional_title_year",
          strategy: "title_year_fallback",
          selected_step: first_evaluation[:selected_step],
          selected_watchable: provisional_watchable,
          conflict_reason: nil
        }
      end

      def unresolved_resolution_for(first_context:, first_evaluation:, recheck_state:, recheck_context:, recheck_evaluation:)
        if recheck_state == Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS && recheck_evaluation.present?
          recheck_status = recheck_evaluation.fetch(:status_code)
          if %w[verified_path verified_external_ids verified_tv_structure ambiguous_conflict].include?(recheck_status)
            return resolution_from_evaluation(recheck_evaluation)
          end
        end

        context = recheck_context || first_context
        evaluation = recheck_evaluation || first_evaluation

        if external_only_path_set?(context: context) && no_arr_evidence?(evaluation)
          return {
            status_code: "external_source_not_managed",
            strategy: "external_unmanaged_path",
            selected_step: nil,
            selected_watchable: evaluation[:selected_watchable],
            conflict_reason: nil
          }
        end

        {
          status_code: "unresolved",
          strategy: "no_match",
          selected_step: nil,
          selected_watchable: evaluation[:selected_watchable],
          conflict_reason: nil
        }
      end

      def no_arr_evidence?(evaluation)
        evaluation.dig(:path, :candidate_count).to_i.zero? &&
          evaluation.dig(:external_ids, :candidate_count).to_i.zero?
      end

      def resolution_from_evaluation(evaluation)
        {
          status_code: evaluation.fetch(:status_code),
          strategy: evaluation.fetch(:strategy),
          selected_step: evaluation[:selected_step],
          selected_watchable: evaluation[:selected_watchable],
          conflict_reason: evaluation[:conflict_reason]
        }
      end

      def apply_plex_rating_key_conflict_rule(resolution:, row:)
        watchable = resolution[:selected_watchable]
        incoming_rating_key = row[:plex_rating_key].to_s.strip.presence
        return resolution.merge(allow_overwrite_rating_key: false) if watchable.blank? || incoming_rating_key.blank?

        existing_rating_key = watchable.plex_rating_key.to_s.strip.presence
        return resolution.merge(allow_overwrite_rating_key: false) if existing_rating_key.blank?
        return resolution.merge(allow_overwrite_rating_key: false) if existing_rating_key == incoming_rating_key

        if resolution[:status_code] == "verified_path"
          return resolution.merge(allow_overwrite_rating_key: true)
        end

        resolution.merge(
          status_code: "ambiguous_conflict",
          strategy: "conflict_detected",
          conflict_reason: Sync::TautulliLibraryMappingSync::CONFLICT_REASON_PLEX_RATING_KEY_CONFLICT,
          allow_overwrite_rating_key: false
        )
      end

      def canonical_path_for(raw_path:, canonical_mapper:)
        value = raw_path.to_s.strip
        return nil if value.blank?

        normalized_path_for(canonical_mapper.canonicalize(value))
      end

      def normalized_path_for(raw_path)
        normalized = Paths::Normalizer.normalize(raw_path)
        normalized.presence
      end

      def ordered_work_items_for(work_items:)
        ordered = work_items.sort_by { |item| item.fetch(:discovery_sequence) }
        return ordered unless profile == :scheduled

        ordered.sort_by do |item|
          first_status = item.dig(:first_evaluation, :status_code).to_s
          [
            scheduled_priority_rank_for(first_status),
            item.fetch(:discovery_sequence)
          ]
        end
      end

      def scheduled_priority_rank_for(status_code)
        case status_code
        when "provisional_title_year"
          0
        when "unresolved"
          1
        else
          2
        end
      end

      def increment_recheck_counters!(counts:, first_status:, outcome:)
        return unless first_status.in?(Sync::TautulliLibraryMappingSync::RECHECK_ELIGIBLE_STATUSES)

        counts[:recheck_eligible_rows] += 1
        counts[:provisional_seen] += 1 if first_status == "provisional_title_year"
        Array(outcome[:enrichment_events]).each do |event|
          increment_enrichment_context_counter!(
            counts: counts,
            source_context: event.fetch(:source_context),
            endpoint_context: event.fetch(:endpoint_context),
            outcome: event.fetch(:outcome)
          )
        end

        case outcome.fetch(:state)
        when Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SUCCESS
          if outcome.fetch(:metadata_call_issued, false)
            counts[:metadata_recheck_attempted] += 1
          else
            counts[:metadata_recheck_skipped] += 1
          end
          if first_status == "provisional_title_year"
            counts[:provisional_rechecked] += 1
          else
            counts[:unresolved_rechecked] += 1
          end
        when Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_SKIPPED
          if outcome.fetch(:metadata_call_issued, false)
            counts[:metadata_recheck_attempted] += 1
          else
            counts[:metadata_recheck_skipped] += 1
          end
          if first_status == "unresolved" && !outcome.fetch(:metadata_call_issued, false)
            counts[:unresolved_recheck_skipped] += 1
          end
        when Sync::TautulliLibraryMappingSync::RECHECK_OUTCOME_FAILED
          if outcome.fetch(:metadata_call_issued, false)
            counts[:metadata_recheck_attempted] += 1
            counts[:metadata_recheck_failed] += 1
          else
            counts[:metadata_recheck_skipped] += 1
          end
          if first_status == "unresolved" && outcome.fetch(:metadata_call_issued, false)
            counts[:unresolved_recheck_failed] += 1
          end
        end
      end

      def increment_enrichment_context_counter!(counts:, source_context:, endpoint_context:, outcome:)
        key = self.class.enrichment_counter_key(
          source_context: source_context,
          endpoint_context: endpoint_context,
          outcome: outcome
        )
        counts[key] = counts.fetch(key, 0) + 1
        return unless outcome == "failed"

        attempted_key = self.class.enrichment_counter_key(
          source_context: source_context,
          endpoint_context: endpoint_context,
          outcome: "attempted"
        )
        counts[attempted_key] = counts.fetch(attempted_key, 0) + 1
      end

      def increment_transition_counters!(counts:, first_status:, final_status:)
        if first_status == "provisional_title_year"
          case final_status
          when "verified_path", "verified_external_ids"
            counts[:provisional_promoted] += 1
          when "ambiguous_conflict"
            counts[:provisional_conflicted] += 1
          else
            counts[:provisional_still_provisional] += 1
          end
        end

        if first_status == "unresolved"
          if final_status == "external_source_not_managed"
            counts[:unresolved_reclassified_external] += 1
          elsif final_status == "unresolved"
            counts[:unresolved_still_unresolved] += 1
          end
        end
      end

      def status_counter_key_for(status_code)
        case status_code
        when "verified_path"
          :status_verified_path
        when "verified_external_ids"
          :status_verified_external_ids
        when "verified_tv_structure"
          :status_verified_tv_structure
        when "provisional_title_year"
          :status_provisional_title_year
        when "external_source_not_managed"
          :status_external_source_not_managed
        when "ambiguous_conflict"
          :status_ambiguous_conflict
        else
          :status_unresolved
        end
      end

      def watchable_type_matches_media_type?(watchable:, media_type:)
        return watchable.is_a?(Movie) if media_type == "movie"
        return watchable.is_a?(Episode) if media_type == "episode"

        false
      end

      def movie_matches_for_external_ids(external_ids:)
        imdb_id = external_ids[:imdb_id].to_s.presence
        tmdb_id = external_ids[:tmdb_id]
        matches = []

        if imdb_id.present?
          ensure_movie_external_id_index!(index_key: :by_imdb_id, column_name: :imdb_id, value: imdb_id)
          matches.concat(@movie_match_index.fetch(:by_imdb_id).fetch(imdb_id, []))
        end
        if tmdb_id.present?
          ensure_movie_external_id_index!(index_key: :by_tmdb_id, column_name: :tmdb_id, value: tmdb_id)
          matches.concat(@movie_match_index.fetch(:by_tmdb_id).fetch(tmdb_id, []))
        end

        matches.uniq(&:id)
      end

      def episode_matches_for_external_ids(external_ids:)
        imdb_id = external_ids[:imdb_id].to_s.presence
        tmdb_id = external_ids[:tmdb_id]
        tvdb_id = external_ids[:tvdb_id]
        matches = []

        if imdb_id.present?
          ensure_episode_external_id_index!(index_key: :by_imdb_id, column_name: :imdb_id, value: imdb_id)
          matches.concat(@episode_match_index.fetch(:by_imdb_id).fetch(imdb_id, []))
        end
        if tmdb_id.present?
          ensure_episode_external_id_index!(index_key: :by_tmdb_id, column_name: :tmdb_id, value: tmdb_id)
          matches.concat(@episode_match_index.fetch(:by_tmdb_id).fetch(tmdb_id, []))
        end
        if tvdb_id.present?
          ensure_episode_external_id_index!(index_key: :by_tvdb_id, column_name: :tvdb_id, value: tvdb_id)
          matches.concat(@episode_match_index.fetch(:by_tvdb_id).fetch(tvdb_id, []))
        end

        matches.uniq(&:id)
      end

      def ensure_movie_external_id_index!(index_key:, column_name:, value:)
        bucket = @movie_match_index.fetch(index_key)
        return if bucket.key?(value)

        bucket[value] = Movie.where(column_name => value).to_a
      end

      def ensure_episode_external_id_index!(index_key:, column_name:, value:)
        bucket = @episode_match_index.fetch(index_key)
        return if bucket.key?(value)

        bucket[value] = Episode.where(column_name => value).to_a
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

      def same_watchable?(left, right)
        return false if left.blank? || right.blank?

        left.class.name == right.class.name && left.id == right.id
      end

      def unique_watchables(watchables)
        Array(watchables).compact.uniq { |watchable| [ watchable.class.name, watchable.id ] }
      end

      def effective_file_paths_for(row:, metadata:)
        candidate_paths = [ row[:file_path] ]
        candidate_paths.concat(Array(metadata&.fetch(:file_paths, nil)))
        candidate_paths << metadata&.fetch(:file_path, nil)
        candidate_paths.filter_map { |path| path.to_s.strip.presence }.uniq
      end

      def path_candidates_for(raw_paths:, canonical_mapper:, root_classifier:)
        Array(raw_paths).filter_map do |raw_path|
          canonical_path = canonical_path_for(raw_path: raw_path, canonical_mapper: canonical_mapper)
          next if canonical_path.blank?

          ownership = root_classifier.classify(canonical_path)
          {
            raw_path: raw_path,
            canonical_path: canonical_path,
            normalized_path: ownership[:normalized_path],
            ownership: ownership[:ownership],
            matched_managed_root: ownership[:matched_managed_root]
          }
        end
      end

      def selected_path_candidate_for(path_candidates:)
        managed_candidate = Array(path_candidates).find { |candidate| candidate[:ownership] == "managed" }
        managed_candidate || Array(path_candidates).first
      end

      def path_set_ownership_for(path_candidates:)
        return nil if path_candidates.blank?
        return "mixed" if mixed_path_sources?(path_candidates: path_candidates)

        path_candidates.any? { |candidate| candidate[:ownership] == "managed" } ? "managed" : "external"
      end

      def mixed_path_sources?(path_candidates:)
        managed_present = Array(path_candidates).any? { |candidate| candidate[:ownership] == "managed" }
        external_present = Array(path_candidates).any? { |candidate| candidate[:ownership] == "external" }

        managed_present && external_present
      end

      def external_only_path_set?(context:)
        !context.fetch(:has_managed_path_candidate, false)
      end

      def empty_path_result
        {
          canonical_path: nil,
          candidate_count: 0,
          expected_candidate_count: 0,
          unique_watchable: nil,
          mismatch_present: false,
          candidate_paths: []
        }
      end

      def empty_external_result
        {
          candidate_count: 0,
          unique_watchable: nil,
          external_ids: {}
        }
      end

      def empty_title_year_result
        {
          candidate_count: 0,
          unique_watchable: nil,
          key: nil
        }
      end

      def normalized_title_for_match(value)
        value.to_s.strip.downcase.presence
      end

      def normalized_year_for_match(value)
        parsed = Integer(value.to_s, exception: false)
        parsed&.positive? ? parsed : nil
      end
    end
  end
end
