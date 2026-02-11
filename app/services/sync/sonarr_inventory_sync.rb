module Sync
  class SonarrInventorySync
    def initialize(sync_run:, correlation_id:, phase_progress: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_progress = phase_progress
    end

    def call
      counts = {
        integrations: 0,
        series_fetched: 0,
        episodes_fetched: 0,
        media_files_fetched: 0,
        episodes_estimated: 0,
        media_files_estimated: 0,
        series_upserted: 0,
        episodes_upserted: 0,
        media_files_upserted: 0
      }

      log_info("sync_phase_worker_started phase=sonarr_inventory")
      Integration.sonarr.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::SonarrAdapter.new(integration:)
        mapper = CanonicalPathMapper.new(integration:)
        worker_count = integration.sonarr_fetch_workers_resolved

        series_rows = adapter.fetch_series
        estimated_episode_rows = series_rows.sum { |series_row| series_row.dig(:statistics, :total_episode_count).to_i }
        estimated_file_rows = series_rows.sum { |series_row| series_row.dig(:statistics, :episode_file_count).to_i }
        estimated_child_rows = estimated_episode_rows + estimated_file_rows

        phase_progress&.add_total!(series_rows.size + estimated_child_rows)
        counts[:series_fetched] += series_rows.size
        counts[:episodes_estimated] += estimated_episode_rows
        counts[:media_files_estimated] += estimated_file_rows
        upserted_series = upsert_series!(integration:, rows: series_rows)
        counts[:series_upserted] += upserted_series
        phase_progress&.advance!(series_rows.size)

        process_series_children_concurrently(
          integration: integration,
          series_rows: series_rows,
          worker_count: worker_count
        ) do |payload|
          series_row = payload.fetch(:series_row)
          episode_rows = payload.fetch(:episode_rows)
          file_rows = payload.fetch(:file_rows)
          fetch_duration_ms = payload.fetch(:fetch_duration_ms)

          total_child_rows = episode_rows.size + file_rows.size
          estimated_child_rows_for_series = estimated_child_rows_for(series_row)
          phase_progress&.add_total!(total_child_rows - estimated_child_rows_for_series) if total_child_rows > estimated_child_rows_for_series

          counts[:episodes_fetched] += episode_rows.size
          counts[:media_files_fetched] += file_rows.size

          upserted_episodes, upserted_files = upsert_series_children!(
            integration: integration,
            series_row: series_row,
            episode_rows: episode_rows,
            file_rows: file_rows,
            mapper: mapper
          )
          counts[:episodes_upserted] += upserted_episodes
          counts[:media_files_upserted] += upserted_files
          phase_progress&.advance!(total_child_rows)

          log_info(
            "sync_phase_worker_series_complete phase=sonarr_inventory integration_id=#{integration.id} " \
            "series_id=#{series_row.fetch(:sonarr_series_id)} episodes_fetched=#{episode_rows.size} " \
            "media_files_fetched=#{file_rows.size} fetch_duration_ms=#{fetch_duration_ms}"
          )
        end

        log_info(
          "sync_phase_worker_integration_complete phase=sonarr_inventory integration_id=#{integration.id} " \
          "workers=#{worker_count} series_fetched=#{counts[:series_fetched]} " \
          "episodes_estimated=#{counts[:episodes_estimated]} episodes_fetched=#{counts[:episodes_fetched]} " \
          "media_files_estimated=#{counts[:media_files_estimated]} media_files_fetched=#{counts[:media_files_fetched]}"
        )
      end

      log_info("sync_phase_worker_completed phase=sonarr_inventory counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :phase_progress, :sync_run

    def process_series_children_concurrently(integration:, series_rows:, worker_count:)
      return if series_rows.empty?

      work_queue = Queue.new
      result_queue = Queue.new

      series_rows.each { |series_row| work_queue << series_row }
      worker_count.times { work_queue << nil }

      threads = Array.new(worker_count) do
        Thread.new do
          thread_adapter = Integrations::SonarrAdapter.new(integration: integration)

          loop do
            series_row = work_queue.pop
            break if series_row.nil?

            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            series_id = series_row.fetch(:sonarr_series_id)
            episode_rows = thread_adapter.fetch_episodes(series_id: series_id)
            file_rows = thread_adapter.fetch_episode_files(series_id: series_id)
            fetch_duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

            result_queue << {
              series_row: series_row,
              episode_rows: episode_rows,
              file_rows: file_rows,
              fetch_duration_ms: fetch_duration_ms
            }
          rescue StandardError => error
            result_queue << { error: error }
          end
        end
      end

      first_error = nil
      series_rows.size.times do
        result = result_queue.pop
        if result[:error].present?
          first_error ||= result.fetch(:error)
          next
        end

        yield result if first_error.nil?
      end

      raise first_error if first_error.present?
    ensure
      threads&.each(&:join)
    end

    def estimated_child_rows_for(series_row)
      statistics = series_row[:statistics] || {}
      statistics.fetch(:total_episode_count, 0).to_i + statistics.fetch(:episode_file_count, 0).to_i
    end

    def upsert_series!(integration:, rows:)
      return 0 if rows.empty?

      existing_by_source_id = Series.where(
        integration_id: integration.id,
        sonarr_series_id: rows.map { |row| row.fetch(:sonarr_series_id) }
      ).index_by(&:sonarr_series_id)

      now = Time.current
      payload = rows.map do |row|
        existing = existing_by_source_id[row.fetch(:sonarr_series_id)]
        {
          integration_id: integration.id,
          sonarr_series_id: row.fetch(:sonarr_series_id),
          title: row.fetch(:title),
          year: row[:year],
          tvdb_id: row[:tvdb_id],
          imdb_id: row[:imdb_id],
          tmdb_id: row[:tmdb_id],
          plex_rating_key: resolved_plex_value(existing_value: existing&.plex_rating_key, incoming_value: row[:plex_rating_key]),
          plex_guid: resolved_plex_value(existing_value: existing&.plex_guid, incoming_value: row[:plex_guid]),
          metadata_json: merged_metadata_json(existing_metadata: existing&.metadata_json, incoming_metadata: row[:metadata] || {}),
          created_at: existing&.created_at || now,
          updated_at: now
        }
      end

      Series.upsert_all(payload, unique_by: %i[integration_id sonarr_series_id])
      payload.size
    end

    def upsert_series_children!(integration:, series_row:, episode_rows:, file_rows:, mapper:)
      series = Series.find_by!(
        integration_id: integration.id,
        sonarr_series_id: series_row.fetch(:sonarr_series_id)
      )
      upserted_episodes = upsert_episodes!(integration:, series:, rows: episode_rows)
      upserted_files = upsert_episode_files!(
        integration: integration,
        episode_rows: episode_rows,
        file_rows: file_rows,
        mapper: mapper
      )
      [ upserted_episodes, upserted_files ]
    end

    def upsert_episodes!(integration:, series:, rows:)
      return 0 if rows.empty?

      season_numbers = rows.map { |row| row.fetch(:season_number) }.uniq
      now = Time.current
      existing_season_by_number = Season.where(series_id: series.id, season_number: season_numbers).index_by(&:season_number)
      season_payload = season_numbers.map do |season_number|
        existing = existing_season_by_number[season_number]
        {
          series_id: series.id,
          season_number: season_number,
          created_at: existing&.created_at || now,
          updated_at: now
        }
      end
      Season.upsert_all(season_payload, unique_by: %i[series_id season_number])

      season_by_number = Season.where(series_id: series.id, season_number: season_numbers).index_by(&:season_number)
      existing_by_source_id = Episode.where(
        integration_id: integration.id,
        sonarr_episode_id: rows.map { |row| row.fetch(:sonarr_episode_id) }
      ).index_by(&:sonarr_episode_id)
      payload = rows.map do |row|
        existing = existing_by_source_id[row.fetch(:sonarr_episode_id)]
        {
          integration_id: integration.id,
          season_id: season_by_number.fetch(row.fetch(:season_number)).id,
          sonarr_episode_id: row.fetch(:sonarr_episode_id),
          episode_number: row.fetch(:episode_number),
          title: row[:title],
          air_date: row[:air_date],
          duration_ms: row[:duration_ms],
          tvdb_id: row[:tvdb_id],
          imdb_id: row[:imdb_id],
          tmdb_id: row[:tmdb_id],
          plex_rating_key: resolved_plex_value(existing_value: existing&.plex_rating_key, incoming_value: row[:plex_rating_key]),
          plex_guid: resolved_plex_value(existing_value: existing&.plex_guid, incoming_value: row[:plex_guid]),
          metadata_json: merged_metadata_json(
            existing_metadata: existing&.metadata_json,
            incoming_metadata: { external_ids: row[:external_ids] || {} }
          ),
          created_at: existing&.created_at || now,
          updated_at: now
        }
      end

      Episode.upsert_all(payload, unique_by: %i[integration_id sonarr_episode_id])
      payload.size
    end

    def upsert_episode_files!(integration:, episode_rows:, file_rows:, mapper:)
      return 0 if file_rows.empty?

      episode_ids_by_source = Episode.where(
        integration_id: integration.id,
        sonarr_episode_id: episode_rows.map { |row| row.fetch(:sonarr_episode_id) }
      ).pluck(:sonarr_episode_id, :id).to_h
      episode_source_ids_by_file = episode_rows.each_with_object({}) do |episode_row, index|
        episode_file_id = episode_row[:episode_file_id].to_i
        next unless episode_file_id.positive?

        index[episode_file_id] = episode_row.fetch(:sonarr_episode_id)
      end
      existing_file_by_arr_file_id = MediaFile.where(
        integration_id: integration.id,
        arr_file_id: file_rows.map { |row| row.fetch(:arr_file_id) }
      ).index_by(&:arr_file_id)

      now = Time.current
      payload = file_rows.filter_map do |row|
        source_episode_id = row[:sonarr_episode_id] || episode_source_ids_by_file[row.fetch(:arr_file_id)]
        episode_id = episode_ids_by_source[source_episode_id]
        next if episode_id.blank?
        existing = existing_file_by_arr_file_id[row.fetch(:arr_file_id)]

        {
          attachable_type: "Episode",
          attachable_id: episode_id,
          integration_id: integration.id,
          arr_file_id: row.fetch(:arr_file_id),
          path: row.fetch(:path),
          path_canonical: mapper.canonicalize(row.fetch(:path)),
          size_bytes: row.fetch(:size_bytes),
          quality_json: merged_metadata_json(existing_metadata: existing&.quality_json, incoming_metadata: row[:quality] || {}).merge(
            "arr_file_added_at" => row[:date_added_at]
          ).compact,
          updated_at: now,
          created_at: existing&.created_at || now
        }
      end

      return 0 if payload.empty?

      MediaFile.upsert_all(payload, unique_by: %i[integration_id arr_file_id])
      payload.size
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

    def resolved_plex_value(existing_value:, incoming_value:)
      incoming_present = incoming_value.to_s.strip.presence
      return incoming_present if incoming_present.present?

      existing_value.to_s.strip.presence
    end

    def merged_metadata_json(existing_metadata:, incoming_metadata:)
      existing_hash = existing_metadata.is_a?(Hash) ? existing_metadata : {}
      incoming_hash = incoming_metadata.is_a?(Hash) ? incoming_metadata : {}
      existing_hash.merge(incoming_hash)
    end
  end
end
