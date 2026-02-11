module Integrations
  class RadarrAdapter < BaseAdapter
    def check_health!
      payload = request_json(
        method: :get,
        path: "api/v3/system/status",
        headers: { "X-Api-Key" => integration.api_key }
      )
      check_compatibility!(ensure_present!(payload, :version))
    end

    def fetch_movies
      payload = request_json(
        method: :get,
        path: "api/v3/movie",
        params: { includeMovieFile: true },
        headers: { "X-Api-Key" => integration.api_key }
      )

      Array(payload).map do |movie|
        radarr_movie_id = ensure_present!(movie, :id).to_i
        {
          radarr_movie_id: radarr_movie_id,
          title: ensure_present!(movie, :title).to_s,
          year: movie["year"]&.to_i,
          tmdb_id: movie["tmdbId"]&.to_i,
          imdb_id: movie["imdbId"]&.presence,
          duration_ms: runtime_ms_for(movie),
          has_file: ActiveModel::Type::Boolean.new.cast(movie["hasFile"]),
          movie_file_id: movie["movieFileId"]&.to_i,
          movie_file: normalize_movie_file(movie["movieFile"], radarr_movie_id: radarr_movie_id),
          plex_rating_key: movie["ratings"]&.dig("plex", "ratingKey"),
          plex_guid: movie["ratings"]&.dig("plex", "guid"),
          metadata: {
            path: movie["path"],
            monitored: movie["monitored"],
            arr_added_at: movie["added"]
          }.compact
        }
      end
    end

    def fetch_movie_files(movie_id:)
      payload = request_json(
        method: :get,
        path: "api/v3/moviefile",
        params: { movieId: movie_id },
        headers: { "X-Api-Key" => integration.api_key }
      )

      Array(payload).map { |movie_file| normalize_movie_file(movie_file) }
    end

    def delete_movie_file!(arr_file_id:)
      request_json(
        method: :delete,
        path: "api/v3/moviefile/#{arr_file_id}",
        headers: { "X-Api-Key" => integration.api_key }
      )
      { deleted: true }
    rescue ConnectivityError, ContractMismatchError => error
      return { deleted: true, already_deleted: true } if not_found_error?(error)

      raise
    end

    def unmonitor_movie!(radarr_movie_id:)
      movie = request_json(
        method: :get,
        path: "api/v3/movie/#{radarr_movie_id}",
        headers: { "X-Api-Key" => integration.api_key }
      )
      request_json(
        method: :put,
        path: "api/v3/movie/#{radarr_movie_id}",
        headers: { "X-Api-Key" => integration.api_key, "Content-Type" => "application/json" },
        body: movie.merge("monitored" => false).to_json
      )
      { updated: true }
    end

    def ensure_tag!(name:)
      tags = request_json(
        method: :get,
        path: "api/v3/tag",
        headers: { "X-Api-Key" => integration.api_key }
      )
      existing = Array(tags).find { |tag| tag["label"].to_s.casecmp(name).zero? }
      return { arr_tag_id: existing.fetch("id").to_i } if existing.present?

      payload = request_json(
        method: :post,
        path: "api/v3/tag",
        headers: { "X-Api-Key" => integration.api_key, "Content-Type" => "application/json" },
        body: { label: name }.to_json
      )
      { arr_tag_id: ensure_present!(payload, :id).to_i }
    end

    def add_movie_tag!(radarr_movie_id:, arr_tag_id:)
      movie = request_json(
        method: :get,
        path: "api/v3/movie/#{radarr_movie_id}",
        headers: { "X-Api-Key" => integration.api_key }
      )
      tags = Array(movie["tags"]).map(&:to_i)
      request_json(
        method: :put,
        path: "api/v3/movie/#{radarr_movie_id}",
        headers: { "X-Api-Key" => integration.api_key, "Content-Type" => "application/json" },
        body: movie.merge("tags" => (tags | [ arr_tag_id.to_i ])).to_json
      )
      { updated: true }
    end

    private

    def runtime_ms_for(movie)
      runtime = movie["runtime"]
      runtime.present? ? runtime.to_i * 60_000 : nil
    end

    def normalize_movie_file(movie_file, radarr_movie_id: nil)
      return nil if movie_file.blank?

      {
        arr_file_id: ensure_present!(movie_file, :id).to_i,
        radarr_movie_id: (radarr_movie_id || ensure_present!(movie_file, :movieId)).to_i,
        path: ensure_present!(movie_file, :path).to_s,
        size_bytes: ensure_present!(movie_file, :size).to_i,
        quality: movie_file["quality"] || {},
        date_added_at: movie_file["dateAdded"]
      }
    end

    def not_found_error?(error)
      error.details[:status].to_i == 404 || error.message.include?("404")
    end
  end
end
