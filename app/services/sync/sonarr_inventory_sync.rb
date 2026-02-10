module Sync
  class SonarrInventorySync
    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      counts = {
        integrations: 0,
        series_fetched: 0,
        episodes_fetched: 0,
        media_files_fetched: 0,
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

        series_rows = adapter.fetch_series
        counts[:series_fetched] += series_rows.size
        upserted_series = upsert_series!(integration:, rows: series_rows)
        counts[:series_upserted] += upserted_series

        series_rows.each do |series_row|
          episode_rows = adapter.fetch_episodes(series_id: series_row[:sonarr_series_id])
          file_rows = adapter.fetch_episode_files(series_id: series_row[:sonarr_series_id])

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
        end

        log_info(
          "sync_phase_worker_integration_complete phase=sonarr_inventory integration_id=#{integration.id} " \
          "series_fetched=#{counts[:series_fetched]} episodes_fetched=#{counts[:episodes_fetched]} " \
          "media_files_fetched=#{counts[:media_files_fetched]}"
        )
      end

      log_info("sync_phase_worker_completed phase=sonarr_inventory counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

    def upsert_series!(integration:, rows:)
      return 0 if rows.empty?

      now = Time.current
      payload = rows.map do |row|
        {
          integration_id: integration.id,
          sonarr_series_id: row.fetch(:sonarr_series_id),
          title: row.fetch(:title),
          year: row[:year],
          tvdb_id: row[:tvdb_id],
          imdb_id: row[:imdb_id],
          tmdb_id: row[:tmdb_id],
          plex_rating_key: row[:plex_rating_key],
          plex_guid: row[:plex_guid],
          metadata_json: row[:metadata] || {},
          created_at: now,
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
      season_payload = season_numbers.map do |season_number|
        {
          series_id: series.id,
          season_number: season_number,
          created_at: now,
          updated_at: now
        }
      end
      Season.upsert_all(season_payload, unique_by: %i[series_id season_number])

      season_by_number = Season.where(series_id: series.id, season_number: season_numbers).index_by(&:season_number)
      payload = rows.map do |row|
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
          plex_rating_key: row[:plex_rating_key],
          plex_guid: row[:plex_guid],
          metadata_json: { external_ids: row[:external_ids] || {} },
          created_at: now,
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

      now = Time.current
      payload = file_rows.filter_map do |row|
        episode_id = episode_ids_by_source[row[:sonarr_episode_id]]
        next if episode_id.blank?

        {
          attachable_type: "Episode",
          attachable_id: episode_id,
          integration_id: integration.id,
          arr_file_id: row.fetch(:arr_file_id),
          path: row.fetch(:path),
          path_canonical: mapper.canonicalize(row.fetch(:path)),
          size_bytes: row.fetch(:size_bytes),
          quality_json: row[:quality] || {},
          updated_at: now,
          created_at: now
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
  end
end
