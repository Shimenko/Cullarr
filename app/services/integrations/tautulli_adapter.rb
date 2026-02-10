module Integrations
  class TautulliAdapter < BaseAdapter
    def check_health!
      payload = request_json(
        method: :get,
        path: "api/v2",
        params: base_api_params.merge(cmd: "get_tautulli_info")
      )

      data = response_data(payload)
      check_compatibility!(ensure_present!(data, :tautulli_version))
    end

    def fetch_users
      payload = request_json(
        method: :get,
        path: "api/v2",
        params: base_api_params.merge(cmd: "get_users")
      )

      Array(response_data(payload)).map do |user|
        {
          tautulli_user_id: ensure_present!(user, :user_id).to_i,
          friendly_name: ensure_present!(user, :friendly_name).to_s,
          is_hidden: ActiveModel::Type::Boolean.new.cast(user["is_active"]) == false
        }
      end
    end

    def fetch_history_page(start:, length:, order_column:, order_dir:, since_row_id: nil, since_timestamp: nil)
      params = base_api_params.merge(
        cmd: "get_history",
        start: start,
        length: length,
        order_column: order_column,
        order_dir: order_dir
      )
      params[:since_row_id] = since_row_id if since_row_id.present?
      params[:since] = since_timestamp.to_i if since_timestamp.present?

      payload = request_json(method: :get, path: "api/v2", params:)
      data = response_data(payload)

      rows = Array(data["data"]).map { |row| normalize_history_row(row) }
      records_total = data["recordsFiltered"] || data["recordsTotal"] || rows.size
      next_start = start.to_i + rows.size
      has_more = next_start < records_total.to_i

      {
        rows: rows,
        records_total: records_total.to_i,
        has_more: has_more,
        next_start: next_start
      }
    end

    def fetch_metadata(rating_key:)
      payload = request_json(
        method: :get,
        path: "api/v2",
        params: base_api_params.merge(cmd: "get_metadata", rating_key: rating_key)
      )
      data = response_data(payload)
      {
        duration_ms: data["duration"]&.to_i,
        plex_guid: data["guid"],
        external_ids: {
          imdb_id: data["imdb_id"],
          tmdb_id: data["tmdb_id"],
          tvdb_id: data["tvdb_id"]
        }.compact
      }
    end

    private

    def base_api_params
      { apikey: integration.api_key }
    end

    def response_data(payload)
      response = ensure_present!(payload, :response)
      result = ensure_present!(response, :result).to_s
      if result != "success"
        raise ContractMismatchError.new(
          "tautulli returned unsuccessful result",
          details: { result: result, message: response["message"] }
        )
      end

      ensure_present!(response, :data)
    end

    def normalize_history_row(row)
      media_type = ensure_present!(row, :media_type).to_s
      unless %w[movie episode].include?(media_type)
        raise ContractMismatchError.new("unsupported tautulli media_type", details: { media_type: media_type })
      end

      {
        history_id: ensure_present!(row, :id).to_i,
        tautulli_user_id: ensure_present!(row, :user_id).to_i,
        media_type: media_type,
        plex_rating_key: ensure_present!(row, :rating_key).to_s,
        viewed_at: Time.zone.at(ensure_present!(row, :date).to_i),
        play_count: row["play_count"].to_i,
        view_offset_ms: row["view_offset"]&.to_i || 0,
        duration_ms: row["duration"]&.to_i
      }
    end
  end
end
