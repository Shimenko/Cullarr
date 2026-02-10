module Sync
  class RadarrInventorySync
    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      counts = {
        integrations: 0,
        movies_fetched: 0,
        media_files_fetched: 0,
        movies_upserted: 0,
        media_files_upserted: 0
      }

      log_info("sync_phase_worker_started phase=radarr_inventory")
      Integration.radarr.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::RadarrAdapter.new(integration:)
        mapper = CanonicalPathMapper.new(integration:)

        movies = adapter.fetch_movies
        movie_files = extract_movie_files(adapter: adapter, movie_rows: movies)

        counts[:movies_fetched] += movies.size
        counts[:media_files_fetched] += movie_files.size
        counts[:movies_upserted] += upsert_movies!(integration:, rows: movies)
        counts[:media_files_upserted] += upsert_movie_files!(
          integration: integration,
          movie_rows: movies,
          file_rows: movie_files,
          mapper: mapper
        )

        log_info(
          "sync_phase_worker_integration_complete phase=radarr_inventory integration_id=#{integration.id} " \
          "movies_fetched=#{counts[:movies_fetched]} media_files_fetched=#{counts[:media_files_fetched]}"
        )
      end

      log_info("sync_phase_worker_completed phase=radarr_inventory counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

    def upsert_movies!(integration:, rows:)
      return 0 if rows.empty?

      now = Time.current
      payload = rows.map do |row|
        {
          integration_id: integration.id,
          radarr_movie_id: row.fetch(:radarr_movie_id),
          title: row.fetch(:title),
          year: row[:year],
          tmdb_id: row[:tmdb_id],
          imdb_id: row[:imdb_id],
          plex_rating_key: row[:plex_rating_key],
          plex_guid: row[:plex_guid],
          duration_ms: row[:duration_ms],
          metadata_json: row[:metadata] || {},
          created_at: now,
          updated_at: now
        }
      end
      Movie.upsert_all(payload, unique_by: %i[integration_id radarr_movie_id])
      payload.size
    end

    def upsert_movie_files!(integration:, movie_rows:, file_rows:, mapper:)
      return 0 if file_rows.empty?

      movie_ids_by_source = Movie.where(
        integration_id: integration.id,
        radarr_movie_id: movie_rows.map { |row| row.fetch(:radarr_movie_id) }
      ).pluck(:radarr_movie_id, :id).to_h

      now = Time.current
      payload = file_rows.filter_map do |row|
        movie_id = movie_ids_by_source[row[:radarr_movie_id]]
        next if movie_id.blank?

        {
          attachable_type: "Movie",
          attachable_id: movie_id,
          integration_id: integration.id,
          arr_file_id: row.fetch(:arr_file_id),
          path: row.fetch(:path),
          path_canonical: mapper.canonicalize(row.fetch(:path)),
          size_bytes: row.fetch(:size_bytes),
          quality_json: row[:quality] || {},
          created_at: now,
          updated_at: now
        }
      end

      return 0 if payload.empty?

      MediaFile.upsert_all(payload, unique_by: %i[integration_id arr_file_id])
      payload.size
    end

    def extract_movie_files(adapter:, movie_rows:)
      from_movies = movie_rows.filter_map { |row| row[:movie_file] }
      fallback_movie_ids = movie_rows.filter_map do |row|
        next if row[:movie_file].present?
        next unless row[:has_file] || row[:movie_file_id].present?

        row.fetch(:radarr_movie_id)
      end

      fallback_rows = fallback_movie_ids.flat_map do |movie_id|
        adapter.fetch_movie_files(movie_id: movie_id)
      end

      from_movies + fallback_rows
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
