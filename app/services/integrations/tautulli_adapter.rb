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

    def fetch_libraries
      payload = request_json(
        method: :get,
        path: "api/v2",
        params: base_api_params.merge(cmd: "get_libraries")
      )

      Array(response_data(payload)).filter_map do |library|
        library_id = integer_or_nil(first_present(library, :section_id, :sectionId, :id))
        next if library_id.blank?

        {
          library_id: library_id,
          title: first_present(library, :section_name, :sectionName, :friendly_name, :name).to_s.presence || "Library #{library_id}",
          section_type: first_present(library, :section_type, :sectionType, :type).to_s.presence
        }.compact
      end
    end

    def fetch_library_media_page(library_id:, start:, length:)
      payload = request_json(
        method: :get,
        path: "api/v2",
        params: base_api_params.merge(
          cmd: "get_library_media_info",
          section_id: library_id,
          start: start,
          length: length
        )
      )
      data = response_data(payload)
      container = data.is_a?(Hash) ? data : {}
      raw_rows = Array(container["data"] || container["items"] || container["rows"] || container["results"] || data)

      rows = []
      skipped_rows = 0
      raw_rows.each do |row|
        normalized = normalize_library_media_row(row)
        if normalized.blank?
          skipped_rows += 1
          next
        end

        rows << normalized
      rescue ContractMismatchError
        skipped_rows += 1
      end

      records_total = container["recordsFiltered"] || container["recordsTotal"] || container["total_count"] || raw_rows.size
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
      guid_external_ids = external_ids_from_guids(
        Array(data["guids"]) + Array(data["parent_guids"]) + Array(data["grandparent_guids"])
      )
      {
        duration_ms: data["duration"]&.to_i,
        plex_guid: data["guid"],
        external_ids: {
          imdb_id: guid_external_ids[:imdb_id] || data["imdb_id"]&.presence,
          tmdb_id: guid_external_ids[:tmdb_id] || integer_or_nil(data["tmdb_id"]),
          tvdb_id: guid_external_ids[:tvdb_id] || integer_or_nil(data["tvdb_id"])
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
        plex_guid: row["guid"]&.to_s&.presence,
        plex_parent_rating_key: row["parent_rating_key"]&.to_s&.presence,
        plex_grandparent_rating_key: row["grandparent_rating_key"]&.to_s&.presence,
        season_number: integer_or_nil(row["parent_media_index"]),
        episode_number: integer_or_nil(row["media_index"]),
        viewed_at: Time.zone.at(ensure_present!(row, :date).to_i),
        play_count: row["play_count"].to_i,
        view_offset_ms: row["view_offset"]&.to_i || 0,
        duration_ms: row["duration"]&.to_i
      }
    end

    def normalize_library_media_row(row)
      media_type = normalize_media_type(first_present(row, :media_type, :mediaType, :type, :library_type))
      return nil unless %w[movie episode].include?(media_type)

      rating_key = first_present(row, :rating_key, :ratingKey)&.to_s&.presence
      file_path = first_present(row, :file, :file_path, :filePath, :path)&.to_s&.presence
      external_ids = external_ids_from_row(row)
      return nil if rating_key.blank? && file_path.blank? && external_ids.blank?

      {
        media_type: media_type,
        plex_rating_key: rating_key,
        plex_guid: first_present(row, :guid, :plex_guid)&.to_s&.presence,
        plex_parent_rating_key: first_present(row, :parent_rating_key, :parentRatingKey)&.to_s&.presence,
        plex_grandparent_rating_key: first_present(row, :grandparent_rating_key, :grandparentRatingKey)&.to_s&.presence,
        season_number: integer_or_nil(first_present(row, :parent_media_index, :parentMediaIndex, :season_number, :seasonNumber)),
        episode_number: integer_or_nil(first_present(row, :media_index, :mediaIndex, :episode_number, :episodeNumber)),
        title: first_present(row, :title, :sort_title)&.to_s&.strip&.presence,
        year: integer_or_nil(first_present(row, :year)),
        plex_added_at: timestamp_from_unix(first_present(row, :added_at, :addedAt)),
        file_path: file_path,
        external_ids: external_ids
      }.compact
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

    def external_ids_from_guids(guids)
      ids = {}

      guids.each do |guid|
        parsed = parse_guid(guid)
        next if parsed.blank?

        key = parsed.fetch(:kind)
        ids[key] ||= parsed.fetch(:value)
      end

      ids
    end

    def parse_guid(guid)
      value = guid.to_s.strip
      return nil if value.blank?

      if (match = value.match(/\Aimdb:\/\/([^?#\/]+)\z/i))
        return { kind: :imdb_id, value: match[1] }
      end

      if (match = value.match(/\Atmdb:\/\/([^?#\/]+)\z/i))
        tmdb_id = integer_or_nil(match[1])
        return { kind: :tmdb_id, value: tmdb_id } if tmdb_id.present?
      end

      if (match = value.match(/\Atvdb:\/\/([^?#\/]+)\z/i))
        tvdb_id = integer_or_nil(match[1])
        return { kind: :tvdb_id, value: tvdb_id } if tvdb_id.present?
      end

      nil
    end

    def external_ids_from_row(row)
      guid_external_ids = external_ids_from_guids(Array(first_present(row, :guids, :Guids)))
      {
        imdb_id: guid_external_ids[:imdb_id] || first_present(row, :imdb_id, :imdbId)&.to_s&.presence,
        tmdb_id: guid_external_ids[:tmdb_id] || integer_or_nil(first_present(row, :tmdb_id, :tmdbId)),
        tvdb_id: guid_external_ids[:tvdb_id] || integer_or_nil(first_present(row, :tvdb_id, :tvdbId))
      }.compact
    end

    def first_present(hash, *keys)
      keys.each do |key|
        value = hash[key.to_s]
        return value if value.present?
      end

      nil
    end

    def normalize_media_type(raw_value)
      value = raw_value.to_s.downcase
      return "movie" if value.in?(%w[movie])
      return "episode" if value.in?(%w[episode])

      nil
    end

    def integer_or_nil(value)
      parsed = Integer(value.to_s, exception: false)
      return nil if parsed.nil? || parsed <= 0

      parsed
    end

    def timestamp_from_unix(value)
      seconds = Integer(value.to_s, exception: false)
      return nil if seconds.nil? || seconds <= 0

      Time.zone.at(seconds).iso8601
    end
  end
end
