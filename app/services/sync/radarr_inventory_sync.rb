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

      Integration.radarr.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::RadarrAdapter.new(integration:)
        mapper = CanonicalPathMapper.new(integration:)

        movies = adapter.fetch_movies
        movie_files = adapter.fetch_movie_files

        counts[:movies_fetched] += movies.size
        counts[:media_files_fetched] += movie_files.size
        counts[:movies_upserted] += upsert_movies!(integration:, rows: movies)
        counts[:media_files_upserted] += upsert_movie_files!(
          integration: integration,
          movie_rows: movies,
          file_rows: movie_files,
          mapper: mapper
        )
      end

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
  end
end
