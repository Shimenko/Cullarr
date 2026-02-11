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
        order_dir: order_dir,
        include_activity: 0
      )
      params[:since_row_id] = since_row_id if since_row_id.present?
      params[:since] = since_timestamp.to_i if since_timestamp.present?

      payload = request_json(method: :get, path: "api/v2", params:)
      data = response_data(payload)

      raw_rows = Array(data["data"])
      rows = []
      skipped_rows = 0
      raw_rows.each do |row|
        normalized = normalize_history_row(row)
        if normalized.blank?
          skipped_rows += 1
          next
        end

        rows << normalized
      rescue ContractMismatchError
        skipped_rows += 1
      end

      records_total = data["recordsFiltered"] || data["recordsTotal"] || raw_rows.size
      next_start = start.to_i + raw_rows.size
      has_more = raw_rows.any? && next_start < records_total.to_i

      {
        rows: rows,
        raw_rows_count: raw_rows.size,
        rows_skipped_invalid: skipped_rows,
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
      return nil unless %w[movie episode].include?(media_type)

      {
        history_id: history_id_from(row),
        tautulli_user_id: ensure_present!(row, :user_id).to_i,
        media_type: media_type,
        plex_rating_key: ensure_present!(row, :rating_key).to_s,
        viewed_at: Time.zone.at(ensure_present!(row, :date).to_i),
        play_count: row["play_count"].to_i,
        view_offset_ms: row["view_offset"]&.to_i || 0,
        duration_ms: row["duration"]&.to_i
      }
    end

    def history_id_from(row)
      %i[row_id id reference_id].each do |key|
        value = row[key.to_s]
        return value.to_i if value.present?
      end

      raise ContractMismatchError.new(
        "integration response did not include required fields",
        details: { missing_key: "history_identity" }
      )
    end
  end
end
