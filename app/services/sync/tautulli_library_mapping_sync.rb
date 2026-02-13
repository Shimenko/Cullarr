module Sync
  class TautulliLibraryMappingSync
    ROW_BUDGET_PER_RUN = 50_000
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

    def initialize(sync_run:, correlation_id:, phase_progress: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_progress = phase_progress
    end

    def call
      counts = {
        integrations: 0,
        libraries_fetched: 0,
        rows_fetched: 0,
        rows_processed: 0,
        rows_invalid: 0,
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
        watchables_unchanged: 0,
        state_updates: 0
      }

      log_info("sync_phase_worker_started phase=tautulli_library_mapping")
      Integration.tautulli.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::TautulliAdapter.new(integration:)
        libraries = adapter.fetch_libraries
        counts[:libraries_fetched] += libraries.size

        integration_counts = process_libraries(integration:, adapter:, libraries:)
        integration_counts.each do |key, value|
          counts[key] += value
        end

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_library_mapping integration_id=#{integration.id} " \
          "libraries_fetched=#{libraries.size} rows_fetched=#{integration_counts[:rows_fetched]} " \
          "rows_processed=#{integration_counts[:rows_processed]} rows_invalid=#{integration_counts[:rows_invalid]} " \
          "rows_mapped_by_path=#{integration_counts[:rows_mapped_by_path]} " \
          "rows_mapped_by_external_ids=#{integration_counts[:rows_mapped_by_external_ids]} " \
          "rows_mapped_by_title_year=#{integration_counts[:rows_mapped_by_title_year]} " \
          "rows_ambiguous=#{integration_counts[:rows_ambiguous]} rows_unmapped=#{integration_counts[:rows_unmapped]} " \
          "watchables_updated=#{integration_counts[:watchables_updated]} " \
          "watchables_unchanged=#{integration_counts[:watchables_unchanged]} " \
          "state_updates=#{integration_counts[:state_updates]}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_library_mapping counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :phase_progress, :sync_run

    def process_libraries(integration:, adapter:, libraries:)
      counts = {
        rows_fetched: 0,
        rows_processed: 0,
        rows_invalid: 0,
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
        watchables_unchanged: 0,
        state_updates: 0
      }
      return counts if libraries.empty?

      @recheck_metadata_cache = {}
      @recheck_show_metadata_cache = {}
      @series_by_rating_key_cache = {}
      @series_by_external_id_cache = {}
      @episode_position_lookup_cache = {}
      state = library_mapping_state_for(integration)
      library_states = state.fetch("libraries")
      budget_remaining = ROW_BUDGET_PER_RUN
      state_changed = false

      phase_progress&.add_total!(libraries.size)
      phase_progress&.advance!(libraries.size)

      libraries.each do |library|
        break if budget_remaining <= 0

        library_id = library.fetch(:library_id).to_s
        library_state = normalized_library_state(library_states[library_id])
        start_offset = library_state.fetch("next_start")

        loop do
          break if budget_remaining <= 0

          page_length = [ integration.tautulli_history_page_size, budget_remaining ].min
          break if page_length <= 0

          page = adapter.fetch_library_media_page(
            library_id: library.fetch(:library_id),
            start: start_offset,
            length: page_length
          )
          fetched_rows = page.fetch(:raw_rows_count, 0).to_i
          rows = page.fetch(:rows)

          phase_progress&.add_total!(fetched_rows + rows.size)
          phase_progress&.advance!(fetched_rows)

          counts[:rows_fetched] += fetched_rows
          counts[:rows_invalid] += page.fetch(:rows_skipped_invalid, 0).to_i

          row_counts = process_rows(rows, integration:, adapter:)
          row_counts.each do |key, value|
            counts[key] += value
          end
          phase_progress&.advance!(rows.size)

          budget_remaining -= fetched_rows
          if fetched_rows <= 0 || !page.fetch(:has_more)
            library_state["next_start"] = 0
            library_state["completed_cycle_count"] += 1
            library_state["last_completed_at"] = Time.current.iso8601
            state_changed = true
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
      end

      state["last_run_at"] = Time.current.iso8601
      state_changed = true

      if state_changed
        persist_library_mapping_state!(integration:, state:)
        counts[:state_updates] += 1
      end

      counts
    end

    # Deterministic transition matrix for first-pass/recheck outcomes:
    #
    # provisional_title_year + success + same unique strong match => verified_path/verified_external_ids
    # provisional_title_year + success + different unique strong match => ambiguous_conflict(id_conflicts_with_provisional)
    # provisional_title_year + success + multiple strong candidates => ambiguous_conflict(multiple_*_candidates)
    # provisional_title_year + skipped/failed => provisional_title_year
    #
    # unresolved + success + unique strong match => verified_path/verified_external_ids
    # unresolved + success + no strong match + (external && no_arr_evidence) => external_source_not_managed
    # unresolved + success + no strong match + !(external && no_arr_evidence) => unresolved
    # unresolved + skipped/failed + (external && no_arr_evidence) => external_source_not_managed
    # unresolved + skipped/failed + !(external && no_arr_evidence) => unresolved
    #
    # Strong-signal consistency check always runs after strict-order tentative selection.
    # It fails closed to ambiguous_conflict on strong-signal disagreement or type mismatch.
    def process_rows(rows, integration:, adapter:)
      counts = {
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
      }
      return counts if rows.empty?

      canonical_mapper = Sync::CanonicalPathMapper.new(integration:)
      root_classifier = Paths::ManagedRootClassifier.new(
        managed_path_roots: AppSetting.db_value_for("managed_path_roots")
      )
      @path_lookup = build_path_lookup(rows:, canonical_mapper:)
      @movie_match_index = build_movie_match_index(rows:)
      @episode_match_index = build_episode_match_index(rows:)
      @movie_title_year_match_index = build_movie_title_year_match_index(rows:)

      rows.each do |row|
        counts[:rows_processed] += 1
        first_context = row_context_for(
          row: row,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier
        )
        first_evaluation = evaluate_context(first_context, integration: integration)
        outcome = recheck_outcome_for(
          row: row,
          first_evaluation: first_evaluation,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier,
          adapter: adapter,
          integration: integration
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

        diagnostics = mapping_diagnostics_for(
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

        persistence = persist_resolution!(
          resolution: final_resolution,
          row: row,
          diagnostics: diagnostics
        )
        if persistence == :updated
          counts[:watchables_updated] += 1
        elsif persistence == :unchanged
          counts[:watchables_unchanged] += 1
        end
      end

      if counts[:metadata_recheck_attempted] + counts[:metadata_recheck_skipped] != counts[:recheck_eligible_rows]
        raise "library mapping metadata recheck invariant violated: attempted + skipped must equal eligible"
      end
      if counts[:metadata_recheck_failed] > counts[:metadata_recheck_attempted]
        raise "library mapping metadata recheck invariant violated: failed must be <= attempted"
      end

      counts
    end

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
      rows = candidates.to_a

      {
        by_imdb_id: rows.group_by(&:imdb_id),
        by_tmdb_id: rows.group_by(&:tmdb_id)
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
      rows = candidates.to_a

      {
        by_imdb_id: rows.group_by(&:imdb_id),
        by_tmdb_id: rows.group_by(&:tmdb_id),
        by_tvdb_id: rows.group_by(&:tvdb_id)
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
      file_path = metadata&.fetch(:file_path, nil).presence || row[:file_path]
      canonical_path = canonical_path_for(raw_path: file_path, canonical_mapper: canonical_mapper)
      ownership = root_classifier.classify(canonical_path)

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
        canonical_path: canonical_path,
        ownership: ownership.fetch(:ownership),
        matched_managed_root: ownership[:matched_managed_root],
        normalized_path: ownership[:normalized_path],
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

    def evaluate_context(context, integration:)
      path_result = resolve_path_candidates(context)
      external_ids_result = resolve_external_id_candidates(context)
      title_year_result = resolve_title_year_candidates(context)
      tv_structure_result = resolve_tv_structure_candidates(context, integration: integration)

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
      canonical_path = context.fetch(:canonical_path).to_s
      return empty_path_result if canonical_path.blank?

      matches = @path_lookup.fetch(canonical_path) do
        fetched = watchables_for_canonical_path(canonical_path)
        @path_lookup[canonical_path] = fetched
      end
      expected_type = context.fetch(:media_type) == "movie" ? Movie : Episode
      expected_matches = matches.select { |watchable| watchable.is_a?(expected_type) }
      unique = expected_matches.one? ? expected_matches.first : nil

      {
        canonical_path: canonical_path,
        candidate_count: matches.size,
        expected_candidate_count: expected_matches.size,
        unique_watchable: unique,
        mismatch_present: expected_matches.empty? && matches.any?
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

    def resolve_tv_structure_candidates(context, integration:)
      return empty_tv_structure_result unless context.fetch(:media_type) == "episode"

      season_episode_keys = {
        season_number: context[:season_number],
        episode_number: context[:episode_number],
        parent_rating_key: context[:plex_parent_rating_key],
        grandparent_rating_key: context[:plex_grandparent_rating_key]
      }
      fallback_path = context[:tv_episode_metadata_fallback] ? "episode_metadata" : nil
      if season_episode_keys[:season_number].blank? || season_episode_keys[:episode_number].blank?
        return {
          outcome: TV_STRUCTURE_OUTCOME_MISSING_KEYS,
          show_identity_source: {
            source: nil,
            value: nil,
            status: TV_STRUCTURE_OUTCOME_MISSING_KEYS
          },
          season_episode_keys: season_episode_keys,
          fallback_path: fallback_path,
          candidate_count: 0,
          unique_watchable: nil,
          conflict_reason: nil
        }
      end

      show_identity = resolve_show_identity_for_tv_structure(context:, integration:)
      if show_identity.fetch(:conflict_reason).present?
        return {
          outcome: TV_STRUCTURE_OUTCOME_AMBIGUOUS,
          show_identity_source: show_identity.fetch(:show_identity_source),
          season_episode_keys: season_episode_keys,
          fallback_path: fallback_path,
          candidate_count: 0,
          unique_watchable: nil,
          conflict_reason: show_identity.fetch(:conflict_reason)
        }
      end

      series = show_identity.fetch(:series)
      if series.blank?
        return {
          outcome: TV_STRUCTURE_OUTCOME_UNRESOLVED_SHOW,
          show_identity_source: show_identity.fetch(:show_identity_source),
          season_episode_keys: season_episode_keys,
          fallback_path: fallback_path,
          candidate_count: 0,
          unique_watchable: nil,
          conflict_reason: nil
        }
      end

      episode_candidates = tv_episode_candidates_for(
        series: series,
        season_number: season_episode_keys.fetch(:season_number),
        episode_number: season_episode_keys.fetch(:episode_number)
      )

      if episode_candidates.size > 1
        return {
          outcome: TV_STRUCTURE_OUTCOME_AMBIGUOUS,
          show_identity_source: show_identity.fetch(:show_identity_source),
          season_episode_keys: season_episode_keys,
          fallback_path: fallback_path,
          candidate_count: episode_candidates.size,
          unique_watchable: nil,
          conflict_reason: CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS
        }
      end

      unique_episode = episode_candidates.first
      if unique_episode.present?
        return {
          outcome: TV_STRUCTURE_OUTCOME_RESOLVED,
          show_identity_source: show_identity.fetch(:show_identity_source),
          season_episode_keys: season_episode_keys,
          fallback_path: fallback_path,
          candidate_count: 1,
          unique_watchable: unique_episode,
          conflict_reason: nil
        }
      end

      {
        outcome: TV_STRUCTURE_OUTCOME_UNRESOLVED_EPISODE,
        show_identity_source: show_identity.fetch(:show_identity_source),
        season_episode_keys: season_episode_keys,
        fallback_path: fallback_path,
        candidate_count: 0,
        unique_watchable: nil,
        conflict_reason: nil
      }
    end

    def resolve_show_identity_for_tv_structure(context:, integration:)
      show_rating_key = context[:plex_grandparent_rating_key].to_s.strip.presence
      show_external_ids = context.fetch(:show_external_ids, {})
      rating_key_candidates = series_candidates_for_show_rating_key(
        show_rating_key: show_rating_key,
        integration_id: integration.id
      )
      external_id_candidates = series_candidates_for_show_external_ids(show_external_ids:)

      rating_key_unique = rating_key_candidates.one? ? rating_key_candidates.first : nil
      external_unique = external_id_candidates.one? ? external_id_candidates.first : nil

      if rating_key_unique.present? && external_unique.present? &&
          !same_watchable?(rating_key_unique, external_unique)
        return {
          series: nil,
          conflict_reason: CONFLICT_REASON_STRONG_SIGNAL_DISAGREEMENT,
          show_identity_source: {
            source: "mixed_show_signals",
            value: {
              grandparent_rating_key: show_rating_key,
              show_external_ids: show_external_ids
            },
            status: "strong_signal_disagreement"
          }
        }
      end

      if rating_key_candidates.size > 1 || external_id_candidates.size > 1
        return {
          series: nil,
          conflict_reason: CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS,
          show_identity_source: {
            source: "mixed_show_signals",
            value: {
              grandparent_rating_key: show_rating_key,
              show_external_ids: show_external_ids
            },
            status: "multiple_candidates"
          }
        }
      end

      if rating_key_unique.present?
        return {
          series: rating_key_unique,
          conflict_reason: nil,
          show_identity_source: {
            source: "plex_grandparent_rating_key",
            value: show_rating_key,
            status: "resolved_unique"
          }
        }
      end

      if external_unique.present?
        return {
          series: external_unique,
          conflict_reason: nil,
          show_identity_source: {
            source: "show_metadata_external_ids",
            value: show_external_ids,
            status: "resolved_unique"
          }
        }
      end

      {
        series: nil,
        conflict_reason: nil,
        show_identity_source: {
          source: nil,
          value: show_rating_key.presence || show_external_ids.presence,
          status: "unresolved"
        }
      }
    end

    def series_candidates_for_show_rating_key(show_rating_key:, integration_id:)
      normalized_key = show_rating_key.to_s.strip.presence
      return [] if normalized_key.blank?

      cache_key = [ integration_id, normalized_key ]
      @series_by_rating_key_cache.fetch(cache_key) do
        @series_by_rating_key_cache[cache_key] = Series.where(plex_rating_key: normalized_key).to_a
      end
    end

    def series_candidates_for_show_external_ids(show_external_ids:)
      normalized_ids = normalized_external_ids(show_external_ids)
      return [] if normalized_ids.blank?

      cache_key = [
        normalized_ids[:tvdb_id],
        normalized_ids[:imdb_id],
        normalized_ids[:tmdb_id]
      ]
      @series_by_external_id_cache.fetch(cache_key) do
        candidates = Series.none
        candidates = candidates.or(Series.where(tvdb_id: normalized_ids[:tvdb_id])) if normalized_ids[:tvdb_id].present?
        candidates = candidates.or(Series.where(imdb_id: normalized_ids[:imdb_id])) if normalized_ids[:imdb_id].present?
        candidates = candidates.or(Series.where(tmdb_id: normalized_ids[:tmdb_id])) if normalized_ids[:tmdb_id].present?
        @series_by_external_id_cache[cache_key] = candidates.to_a.uniq(&:id)
      end
    end

    def tv_episode_candidates_for(series:, season_number:, episode_number:)
      lookup = episode_position_lookup_for_series(series_id: series.id)
      season = lookup.fetch(:seasons)[season_number.to_i]
      return [] if season.blank?

      lookup.fetch(:episodes)[[ season.id, episode_number.to_i ]] || []
    end

    def episode_position_lookup_for_series(series_id:)
      @episode_position_lookup_cache.fetch(series_id) do
        seasons = Season.where(series_id: series_id).select(:id, :season_number).to_a
        seasons_by_number = seasons.index_by(&:season_number)
        season_ids = seasons.map(&:id)
        episodes_by_key = if season_ids.empty?
          {}
        else
          Episode.where(season_id: season_ids)
                 .group_by { |episode| [ episode.season_id, episode.episode_number ] }
        end
        @episode_position_lookup_cache[series_id] = {
          seasons: seasons_by_number,
          episodes: episodes_by_key
        }
      end
    end

    def empty_tv_structure_result
      {
        outcome: TV_STRUCTURE_OUTCOME_NON_TV,
        show_identity_source: {
          source: nil,
          value: nil,
          status: TV_STRUCTURE_OUTCOME_NON_TV
        },
        season_episode_keys: {
          season_number: nil,
          episode_number: nil,
          parent_rating_key: nil,
          grandparent_rating_key: nil
        },
        fallback_path: nil,
        candidate_count: 0,
        unique_watchable: nil,
        conflict_reason: nil
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
      # Conflict precedence is deterministic:
      # 1) non-unique path matches
      # 2) path type mismatches
      # 3) non-unique external-id matches
      # 4) TV-structure-specific ambiguity
      # 5) disagreement across unique strong winners
      return CONFLICT_REASON_MULTIPLE_PATH if path_result.fetch(:expected_candidate_count) > 1
      return CONFLICT_REASON_MULTIPLE_PATH if path_result.fetch(:candidate_count) > 1
      return CONFLICT_REASON_TYPE_MISMATCH if path_result.fetch(:mismatch_present)
      return CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS if external_ids_result.fetch(:candidate_count) > 1
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
        return CONFLICT_REASON_STRONG_SIGNAL_DISAGREEMENT
      end

      selected = strong_unique_watchables.first
      if selected.present? && !watchable_type_matches_media_type?(watchable: selected, media_type: context.fetch(:media_type))
        return CONFLICT_REASON_TYPE_MISMATCH
      end

      nil
    end

    def recheck_outcome_for(row:, first_evaluation:, canonical_mapper:, root_classifier:, adapter:, integration:)
      initial_status = first_evaluation.fetch(:status_code)
      return { state: RECHECK_OUTCOME_NOT_ELIGIBLE } unless RECHECK_ELIGIBLE_STATUSES.include?(initial_status)

      if row[:media_type].to_s == "episode" && initial_status == "unresolved"
        return tv_episode_recheck_outcome_for(
          row: row,
          canonical_mapper: canonical_mapper,
          root_classifier: root_classifier,
          adapter: adapter,
          integration: integration
        )
      end

      rating_key = row[:plex_rating_key].to_s.strip.presence
      if rating_key.blank?
        return {
          state: RECHECK_OUTCOME_SKIPPED,
          reason: "recheck_skipped_missing_rating_key"
        }
      end

      metadata_result = fetch_recheck_metadata_result(adapter:, rating_key:)
      metadata = metadata_result.fetch(:metadata)
      if metadata.blank?
        return {
          state: RECHECK_OUTCOME_SKIPPED,
          reason: "recheck_skipped_cached_metadata_unusable",
          metadata_call_issued: false
        } unless metadata_result.fetch(:call_issued)

        return {
          state: RECHECK_OUTCOME_FAILED,
          reason: "recheck_failed_metadata_lookup",
          metadata_call_issued: true
        }
      end

      context = row_context_for(
        row: row,
        canonical_mapper: canonical_mapper,
        root_classifier: root_classifier,
        metadata: metadata
      )
      evaluation = evaluate_context(context, integration: integration)
      {
        state: RECHECK_OUTCOME_SUCCESS,
        metadata_call_issued: metadata_result.fetch(:call_issued),
        context: context,
        evaluation: evaluation
      }
    end

    def tv_episode_recheck_outcome_for(row:, canonical_mapper:, root_classifier:, adapter:, integration:)
      # Row-level counter semantics:
      # - attempted: at least one metadata call issued for this row
      # - skipped: no metadata call issued for this row
      # - failed: row ends failed after an issued call path yields unusable metadata
      metadata_call_issued = false
      show_context = nil
      show_evaluation = nil
      show_metadata = nil

      show_rating_key = row[:plex_grandparent_rating_key].to_s.strip.presence
      if show_rating_key.present?
        show_metadata_result = fetch_recheck_show_metadata_result(
          adapter: adapter,
          integration_id: integration.id,
          show_rating_key: show_rating_key
        )
        metadata_call_issued ||= show_metadata_result.fetch(:call_issued)
        show_metadata = show_metadata_result.fetch(:metadata)

        if show_metadata.present?
          show_context = row_context_for(
            row: row,
            canonical_mapper: canonical_mapper,
            root_classifier: root_classifier,
            show_metadata: show_metadata
          )
          show_evaluation = evaluate_context(show_context, integration: integration)

          if recheck_success_status?(show_evaluation.fetch(:status_code))
            return {
              state: RECHECK_OUTCOME_SUCCESS,
              reason: "recheck_show_metadata_resolved",
              metadata_call_issued: metadata_call_issued,
              context: show_context,
              evaluation: show_evaluation
            }
          end
        end
      end

      rating_key = row[:plex_rating_key].to_s.strip.presence
      if rating_key.blank?
        return {
          state: metadata_call_issued ? RECHECK_OUTCOME_FAILED : RECHECK_OUTCOME_SKIPPED,
          reason: metadata_call_issued ? "recheck_failed_episode_metadata_missing_rating_key" : "recheck_skipped_missing_rating_key",
          metadata_call_issued: metadata_call_issued,
          context: show_context,
          evaluation: show_evaluation
        }
      end

      metadata_result = fetch_recheck_metadata_result(adapter:, rating_key:)
      metadata_call_issued ||= metadata_result.fetch(:call_issued)
      metadata = metadata_result.fetch(:metadata)

      if metadata.blank?
        return {
          state: metadata_call_issued ? RECHECK_OUTCOME_FAILED : RECHECK_OUTCOME_SKIPPED,
          reason: metadata_result.fetch(:call_issued) ? "recheck_failed_episode_metadata_lookup" : "recheck_skipped_cached_metadata_unusable",
          metadata_call_issued: metadata_call_issued,
          context: show_context,
          evaluation: show_evaluation
        }
      end

      context = row_context_for(
        row: row,
        canonical_mapper: canonical_mapper,
        root_classifier: root_classifier,
        metadata: metadata,
        show_metadata: show_metadata,
        episode_metadata_fallback: true
      )
      evaluation = evaluate_context(context, integration: integration)
      {
        state: RECHECK_OUTCOME_SUCCESS,
        reason: "recheck_episode_metadata_fallback",
        metadata_call_issued: metadata_call_issued,
        context: context,
        evaluation: evaluation
      }
    end

    def fetch_recheck_metadata_result(adapter:, rating_key:)
      cached = @recheck_metadata_cache[rating_key]
      unless cached.nil?
        return {
          metadata: cached == :unusable ? nil : cached,
          call_issued: false
        }
      end

      metadata = adapter.fetch_metadata(rating_key: rating_key)
      if metadata_usable?(metadata)
        @recheck_metadata_cache[rating_key] = metadata
        return { metadata: metadata, call_issued: true }
      end

      @recheck_metadata_cache[rating_key] = :unusable
      { metadata: nil, call_issued: true }
    rescue Integrations::Error, Integrations::ContractMismatchError, StandardError
      @recheck_metadata_cache[rating_key] = :unusable
      { metadata: nil, call_issued: true }
    end

    def fetch_recheck_show_metadata_result(adapter:, integration_id:, show_rating_key:)
      normalized_key = show_rating_key.to_s.strip.presence
      return { metadata: nil, call_issued: false } if normalized_key.blank?

      cache_key = [ integration_id, normalized_key ]
      cached = @recheck_show_metadata_cache[cache_key]
      unless cached.nil?
        return {
          metadata: cached == :unusable ? nil : cached,
          call_issued: false
        }
      end

      metadata = adapter.fetch_metadata(rating_key: normalized_key)
      if metadata_usable_for_show?(metadata)
        @recheck_show_metadata_cache[cache_key] = metadata
        return { metadata: metadata, call_issued: true }
      end

      @recheck_show_metadata_cache[cache_key] = :unusable
      { metadata: nil, call_issued: true }
    rescue Integrations::Error, Integrations::ContractMismatchError, StandardError
      @recheck_show_metadata_cache[cache_key] = :unusable
      { metadata: nil, call_issued: true }
    end

    def metadata_usable?(metadata)
      return false unless metadata.is_a?(Hash)

      has_file_path = metadata[:file_path].to_s.strip.present?
      has_external_ids = normalized_external_ids(metadata.fetch(:external_ids, {})).any?

      has_file_path || has_external_ids
    end

    def metadata_usable_for_show?(metadata)
      return false unless metadata.is_a?(Hash)

      normalized_external_ids(metadata.fetch(:external_ids, {})).any?
    end

    def recheck_success_status?(status_code)
      %w[verified_path verified_external_ids verified_tv_structure ambiguous_conflict].include?(status_code)
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
      # Movie-only provisional flow is intentionally unchanged in Slice E.
      # Conflicts against a different strong winner continue to emit
      # id_conflicts_with_provisional for backward-compatible diagnostics.
      provisional_watchable = first_evaluation.fetch(:selected_watchable)
      if recheck_state == RECHECK_OUTCOME_SUCCESS && recheck_evaluation.present?
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
            conflict_reason: CONFLICT_REASON_ID_CONFLICTS_WITH_PROVISIONAL
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
      if recheck_state == RECHECK_OUTCOME_SUCCESS && recheck_evaluation.present?
        recheck_status = recheck_evaluation.fetch(:status_code)
        if %w[verified_path verified_external_ids verified_tv_structure ambiguous_conflict].include?(recheck_status)
          return resolution_from_evaluation(recheck_evaluation)
        end
      end

      context = recheck_context || first_context
      evaluation = recheck_evaluation || first_evaluation

      if context.fetch(:ownership) == "external" && no_arr_evidence?(evaluation)
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
      evaluation.dig(:path, :unique_watchable).blank? &&
        evaluation.dig(:external_ids, :unique_watchable).blank?
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
        conflict_reason: CONFLICT_REASON_PLEX_RATING_KEY_CONFLICT,
        allow_overwrite_rating_key: false
      )
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

    def canonical_path_for(raw_path:, canonical_mapper:)
      value = raw_path.to_s.strip
      return nil if value.blank?

      normalized_path_for(canonical_mapper.canonicalize(value))
    end

    def normalized_path_for(raw_path)
      normalized = Paths::Normalizer.normalize(raw_path)
      normalized.presence
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

    def persist_library_mapping_state!(integration:, state:)
      settings = integration.settings_json.deep_dup
      settings["library_mapping_state"] = state
      integration.update!(settings_json: settings)
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

    def mapping_diagnostics_for(row:, first_context:, first_evaluation:, recheck_outcome:, final_resolution:)
      recheck_context = recheck_outcome[:context]
      recheck_evaluation = recheck_outcome[:evaluation]
      tv_structure = recheck_evaluation&.fetch(:tv_structure, nil) || first_evaluation.fetch(:tv_structure)

      {
        version: "v2",
        attempt_order: ATTEMPT_ORDER,
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
          raw_path: first_context[:discovery_file_path],
          normalized_path: first_context[:normalized_path],
          canonical_path: first_context[:canonical_path],
          ownership: first_context[:ownership],
          matched_managed_root: first_context[:matched_managed_root],
          first_pass_candidate_count: first_evaluation.dig(:path, :candidate_count).to_i,
          first_pass_expected_candidate_count: first_evaluation.dig(:path, :expected_candidate_count).to_i,
          recheck_normalized_path: recheck_context&.dig(:normalized_path),
          recheck_canonical_path: recheck_context&.dig(:canonical_path),
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

    def tv_structure_diagnostics_payload(tv_structure)
      value = tv_structure.is_a?(Hash) ? tv_structure.deep_dup : {}
      value.delete(:unique_watchable)
      value.delete("unique_watchable")
      value
    end

    def increment_recheck_counters!(counts:, first_status:, outcome:)
      return unless RECHECK_ELIGIBLE_STATUSES.include?(first_status)

      counts[:recheck_eligible_rows] += 1
      counts[:provisional_seen] += 1 if first_status == "provisional_title_year"

      case outcome.fetch(:state)
      when RECHECK_OUTCOME_SUCCESS
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
      when RECHECK_OUTCOME_SKIPPED
        counts[:metadata_recheck_skipped] += 1
        if first_status == "unresolved"
          counts[:unresolved_recheck_skipped] += 1
        end
      when RECHECK_OUTCOME_FAILED
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

    def empty_path_result
      {
        canonical_path: nil,
        candidate_count: 0,
        expected_candidate_count: 0,
        unique_watchable: nil,
        mismatch_present: false
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

    def log_info(message)
      Rails.logger.info(
        [
          message,
          "sync_run_id=#{sync_run.id}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end
  end
end
