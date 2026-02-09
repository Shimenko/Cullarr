module Integrations
  class SonarrAdapter < BaseAdapter
    def check_health!
      payload = request_json(
        method: :get,
        path: "api/v3/system/status",
        headers: { "X-Api-Key" => integration.api_key }
      )
      check_compatibility!(ensure_present!(payload, :version))
    end

    def fetch_series
      payload = request_json(
        method: :get,
        path: "api/v3/series",
        headers: { "X-Api-Key" => integration.api_key }
      )

      Array(payload).map do |series|
        {
          sonarr_series_id: ensure_present!(series, :id).to_i,
          title: ensure_present!(series, :title).to_s,
          year: series["year"]&.to_i,
          tvdb_id: series["tvdbId"]&.to_i,
          imdb_id: series["imdbId"]&.presence,
          tmdb_id: series["tmdbId"]&.to_i,
          plex_rating_key: series["ratings"]&.dig("plex", "ratingKey"),
          plex_guid: series["ratings"]&.dig("plex", "guid"),
          metadata: {
            path: series["path"],
            monitored: series["monitored"]
          }.compact
        }
      end
    end

    def fetch_episodes(series_id:)
      payload = request_json(
        method: :get,
        path: "api/v3/episode",
        params: { seriesId: series_id },
        headers: { "X-Api-Key" => integration.api_key }
      )

      Array(payload).map do |episode|
        {
          sonarr_episode_id: ensure_present!(episode, :id).to_i,
          season_number: ensure_present!(episode, :seasonNumber).to_i,
          episode_number: ensure_present!(episode, :episodeNumber).to_i,
          title: episode["title"],
          air_date: episode["airDate"],
          duration_ms: duration_ms_for(episode),
          tvdb_id: episode["tvdbId"]&.to_i,
          imdb_id: episode["imdbId"]&.presence,
          tmdb_id: episode["tmdbId"]&.to_i,
          plex_rating_key: episode["ratings"]&.dig("plex", "ratingKey"),
          plex_guid: episode["ratings"]&.dig("plex", "guid"),
          external_ids: {
            tvdb_id: episode["tvdbId"],
            imdb_id: episode["imdbId"],
            tmdb_id: episode["tmdbId"]
          }.compact
        }
      end
    end

    def fetch_episode_files(series_id:)
      payload = request_json(
        method: :get,
        path: "api/v3/episodefile",
        params: { seriesId: series_id },
        headers: { "X-Api-Key" => integration.api_key }
      )

      Array(payload).map do |episode_file|
        episode_id = episode_file["episodeId"] || Array(episode_file["episodes"]).first&.dig("id")
        {
          arr_file_id: ensure_present!(episode_file, :id).to_i,
          sonarr_episode_id: episode_id&.to_i,
          path: ensure_present!(episode_file, :path).to_s,
          size_bytes: ensure_present!(episode_file, :size).to_i,
          quality: episode_file["quality"] || {}
        }
      end
    end

    def delete_episode_file!(arr_file_id:)
      request_json(
        method: :delete,
        path: "api/v3/episodefile/#{arr_file_id}",
        headers: { "X-Api-Key" => integration.api_key }
      )
      { deleted: true }
    rescue ConnectivityError => error
      return { deleted: true, already_deleted: true } if error.message.include?("404")

      raise
    end

    def unmonitor_episode!(sonarr_episode_id:)
      request_json(
        method: :put,
        path: "api/v3/episode/#{sonarr_episode_id}",
        headers: { "X-Api-Key" => integration.api_key, "Content-Type" => "application/json" },
        body: { id: sonarr_episode_id, monitored: false }.to_json
      )
      { updated: true }
    end

    def unmonitor_series!(sonarr_series_id:)
      request_json(
        method: :put,
        path: "api/v3/series/#{sonarr_series_id}",
        headers: { "X-Api-Key" => integration.api_key, "Content-Type" => "application/json" },
        body: { id: sonarr_series_id, monitored: false }.to_json
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

    def add_series_tag!(sonarr_series_id:, arr_tag_id:)
      series = request_json(
        method: :get,
        path: "api/v3/series/#{sonarr_series_id}",
        headers: { "X-Api-Key" => integration.api_key }
      )
      tags = Array(series["tags"]).map(&:to_i)
      request_json(
        method: :put,
        path: "api/v3/series/#{sonarr_series_id}",
        headers: { "X-Api-Key" => integration.api_key, "Content-Type" => "application/json" },
        body: series.merge("tags" => (tags | [ arr_tag_id.to_i ])).to_json
      )
      { updated: true }
    end

    private

    def duration_ms_for(episode)
      runtime = episode["runtime"]
      runtime.present? ? runtime.to_i * 60_000 : nil
    end
  end
end
