module Sync
  class TautulliLibraryMappingSync
    ROW_BUDGET_PER_RUN = 50_000

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
        watchables_updated: 0,
        watchables_unchanged: 0,
        state_updates: 0
      }
      return counts if libraries.empty?

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

          row_counts = process_rows(rows)
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

    def process_rows(rows)
      counts = {
        rows_processed: 0,
        rows_mapped_by_path: 0,
        rows_mapped_by_external_ids: 0,
        rows_mapped_by_title_year: 0,
        rows_ambiguous: 0,
        rows_unmapped: 0,
        watchables_updated: 0,
        watchables_unchanged: 0
      }
      return counts if rows.empty?

      path_lookup = build_path_lookup(rows)
      movie_match_index = build_movie_match_index(rows)
      episode_match_index = build_episode_match_index(rows)
      movie_title_year_match_index = build_movie_title_year_match_index(rows)

      rows.each do |row|
        counts[:rows_processed] += 1
        resolution = resolve_watchable(
          row: row,
          path_lookup: path_lookup,
          movie_match_index: movie_match_index,
          episode_match_index: episode_match_index,
          movie_title_year_match_index: movie_title_year_match_index
        )

        case resolution.fetch(:status)
        when :ambiguous
          counts[:rows_ambiguous] += 1
        when :unmapped
          counts[:rows_unmapped] += 1
        else
          result = apply_mapping!(
            watchable: resolution.fetch(:watchable),
            row: row,
            confidence: resolution.fetch(:confidence)
          )

          if result == :ambiguous
            counts[:rows_ambiguous] += 1
            next
          end

          if resolution.fetch(:confidence) == :path
            counts[:rows_mapped_by_path] += 1
          elsif resolution.fetch(:confidence) == :title_year
            counts[:rows_mapped_by_title_year] += 1
          else
            counts[:rows_mapped_by_external_ids] += 1
          end

          if result == :updated
            counts[:watchables_updated] += 1
          else
            counts[:watchables_unchanged] += 1
          end
        end
      end

      counts
    end

    def build_path_lookup(rows)
      paths = rows.filter_map do |row|
        normalized_path_for(row[:file_path])
      end.uniq
      return {} if paths.empty?

      media_rows = MediaFile.where(path_canonical: paths).pluck(:path_canonical, :attachable_type, :attachable_id)
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

    def build_movie_match_index(rows)
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

    def build_episode_match_index(rows)
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

    def build_movie_title_year_match_index(rows)
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

    def resolve_watchable(row:, path_lookup:, movie_match_index:, episode_match_index:, movie_title_year_match_index:)
      path_resolution = resolve_by_path(row:, path_lookup:)
      return path_resolution if path_resolution.present?

      external_resolution = resolve_by_external_ids(
        row: row,
        movie_match_index: movie_match_index,
        episode_match_index: episode_match_index
      )
      return external_resolution if external_resolution.present?

      title_year_resolution = resolve_movie_by_title_and_year(
        row: row,
        movie_title_year_match_index: movie_title_year_match_index
      )
      return title_year_resolution if title_year_resolution.present?

      { status: :unmapped }
    end

    def resolve_by_path(row:, path_lookup:)
      normalized_path = normalized_path_for(row[:file_path])
      return nil if normalized_path.blank?

      matches = path_lookup[normalized_path] || []
      return nil if matches.empty?
      return { status: :ambiguous } if matches.size > 1

      watchable = matches.first
      expected_type = row[:media_type] == "movie" ? Movie : Episode
      return { status: :mapped, watchable: watchable, confidence: :path } if watchable.is_a?(expected_type)

      { status: :ambiguous }
    end

    def resolve_by_external_ids(row:, movie_match_index:, episode_match_index:)
      matches = if row[:media_type] == "movie"
        movie_matches_for_external_ids(external_ids: row.fetch(:external_ids, {}), match_index: movie_match_index)
      else
        episode_matches_for_external_ids(external_ids: row.fetch(:external_ids, {}), match_index: episode_match_index)
      end
      return nil if matches.empty?
      return { status: :ambiguous } if matches.size > 1

      { status: :mapped, watchable: matches.first, confidence: :external_ids }
    end

    def movie_matches_for_external_ids(external_ids:, match_index:)
      matches = []
      imdb_id = external_ids[:imdb_id].to_s.presence
      tmdb_id = external_ids[:tmdb_id]
      matches.concat(match_index.fetch(:by_imdb_id).fetch(imdb_id, [])) if imdb_id.present?
      matches.concat(match_index.fetch(:by_tmdb_id).fetch(tmdb_id, [])) if tmdb_id.present?
      matches.uniq(&:id)
    end

    def episode_matches_for_external_ids(external_ids:, match_index:)
      matches = []
      imdb_id = external_ids[:imdb_id].to_s.presence
      tmdb_id = external_ids[:tmdb_id]
      tvdb_id = external_ids[:tvdb_id]
      matches.concat(match_index.fetch(:by_imdb_id).fetch(imdb_id, [])) if imdb_id.present?
      matches.concat(match_index.fetch(:by_tmdb_id).fetch(tmdb_id, [])) if tmdb_id.present?
      matches.concat(match_index.fetch(:by_tvdb_id).fetch(tvdb_id, [])) if tvdb_id.present?
      matches.uniq(&:id)
    end

    def resolve_movie_by_title_and_year(row:, movie_title_year_match_index:)
      return nil unless row[:media_type] == "movie"

      normalized_title = normalized_title_for_match(row[:title])
      return nil if normalized_title.blank?

      key = [ normalized_title, normalized_year_for_match(row[:year]) ]
      matches = movie_title_year_match_index[key] || []
      return nil if matches.empty?
      return { status: :ambiguous } if matches.size > 1

      { status: :mapped, watchable: matches.first, confidence: :title_year }
    end

    def apply_mapping!(watchable:, row:, confidence:)
      attrs = {}
      metadata = watchable.metadata_json.is_a?(Hash) ? watchable.metadata_json.deep_dup : {}
      incoming_rating_key = row[:plex_rating_key].to_s.strip.presence
      incoming_guid = row[:plex_guid].to_s.strip.presence

      if incoming_rating_key.present?
        existing_rating_key = watchable.plex_rating_key.to_s.strip.presence
        if existing_rating_key.blank?
          attrs[:plex_rating_key] = incoming_rating_key
        elsif existing_rating_key != incoming_rating_key
          if confidence == :path
            attrs[:plex_rating_key] = incoming_rating_key
          else
            metadata["plex_added_at"] = row[:plex_added_at] if row[:plex_added_at].present?
            attrs[:metadata_json] = metadata if metadata_changed?(watchable.metadata_json, metadata)
            attrs.merge!(
              watchable.mapping_state_attributes_for(
                status_code: "ambiguous_conflict",
                strategy: "conflict_detected",
                diagnostics: mapping_diagnostics_for(
                  row: row,
                  confidence: confidence,
                  conflict_reason: "plex_rating_key_conflict"
                )
              )
            )
            persist_watchable_changes!(watchable:, attrs:)
            return :ambiguous
          end
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
          status_code: mapping_status_for_confidence(confidence),
          strategy: mapping_strategy_for_confidence(confidence),
          diagnostics: mapping_diagnostics_for(row:, confidence:)
        )
      )

      persist_watchable_changes!(watchable:, attrs:)
    end

    def normalized_path_for(raw_path)
      value = raw_path.to_s
      return nil if value.blank?

      Paths::Normalizer.normalize(value)
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

    def mapping_status_for_confidence(confidence)
      case confidence
      when :path
        "verified_path"
      when :external_ids
        "verified_external_ids"
      when :title_year
        "provisional_title_year"
      else
        "unresolved"
      end
    end

    def mapping_strategy_for_confidence(confidence)
      case confidence
      when :path
        "path_match"
      when :external_ids
        "external_ids_match"
      when :title_year
        "title_year_fallback"
      else
        "no_match"
      end
    end

    def mapping_diagnostics_for(row:, confidence:, conflict_reason: nil)
      diagnostics = {
        version: "v2",
        attempt_order: [ "path", "external_ids", "tv_structure", "title_year" ],
        selected_step: confidence.to_s,
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
      diagnostics[:conflict_reason] = conflict_reason if conflict_reason.present?
      diagnostics
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
