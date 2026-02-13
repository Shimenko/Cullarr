module Integrations
  class TautulliAdapter < BaseAdapter
    METADATA_ENDPOINT = "get_metadata".freeze
    LIBRARY_MEDIA_ENDPOINT = "get_library_media_info".freeze
    FEED_ROLE_ENRICHMENT = "enrichment_verification".freeze
    FEED_ROLE_DISCOVERY = "discovery".freeze
    SOURCE_STRENGTH_STRONG_ENRICHMENT = "strong_enrichment".freeze
    SOURCE_STRENGTH_SPARSE_DISCOVERY = "sparse_discovery".freeze
    SOURCE_METADATA_MEDIA_INFO_PARTS_FILE = "metadata_media_info_parts_file".freeze
    SOURCE_METADATA_GUIDS = "metadata_guids".freeze
    SOURCE_METADATA_TOP_LEVEL = "metadata_top_level".freeze
    SOURCE_NONE = "none".freeze
    TOP_LEVEL_ID_KEYS = {
      imdb_id: %i[imdb_id imdbId],
      tmdb_id: %i[tmdb_id tmdbId],
      tvdb_id: %i[tvdb_id tvdbId]
    }.freeze

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
          cmd: LIBRARY_MEDIA_ENDPOINT,
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
        normalized = normalize_library_media_row(row, endpoint: LIBRARY_MEDIA_ENDPOINT)
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
        params: base_api_params.merge(cmd: METADATA_ENDPOINT, rating_key: rating_key)
      )
      data = response_data(payload)
      guid_entries = external_id_entries_from_guids(
        Array(data["guids"]) + Array(data["parent_guids"]) + Array(data["grandparent_guids"])
      )
      file_path_signal = metadata_file_path_signal(data)
      id_signals = TOP_LEVEL_ID_KEYS.keys.index_with do |id_kind|
        metadata_external_id_signal(data:, guid_entries:, id_kind: id_kind)
      end

      {
        duration_ms: data["duration"]&.to_i,
        plex_guid: data["guid"],
        file_path: file_path_signal[:value],
        external_ids: id_signals.transform_values { |signal| signal[:value] }.compact,
        provenance: metadata_provenance(file_path_signal:, id_signals:)
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

    def normalize_library_media_row(row, endpoint:)
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
        external_ids: external_ids,
        provenance: discovery_provenance(endpoint:)
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
      external_id_entries_from_guids(guids).transform_values { |entry| entry.fetch(:value) }
    end

    def external_id_entries_from_guids(guids)
      ids = {}

      guids.each do |guid|
        parsed = parse_guid(guid)
        next if parsed.blank?

        key = parsed.fetch(:kind)
        ids[key] ||= { value: parsed.fetch(:value), raw: guid }
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
        imdb_id: guid_external_ids[:imdb_id] || normalize_external_id(kind: :imdb_id, raw_value: first_present(row, *TOP_LEVEL_ID_KEYS.fetch(:imdb_id))),
        tmdb_id: guid_external_ids[:tmdb_id] || normalize_external_id(kind: :tmdb_id, raw_value: first_present(row, *TOP_LEVEL_ID_KEYS.fetch(:tmdb_id))),
        tvdb_id: guid_external_ids[:tvdb_id] || normalize_external_id(kind: :tvdb_id, raw_value: first_present(row, *TOP_LEVEL_ID_KEYS.fetch(:tvdb_id)))
      }.compact
    end

    def metadata_external_id_signal(data:, guid_entries:, id_kind:)
      guid_entry = guid_entries[id_kind]
      if guid_entry.present?
        chosen_value = guid_entry.fetch(:value)
        return signal_payload(
          source: SOURCE_METADATA_GUIDS,
          raw: guid_entry[:raw],
          normalized: chosen_value,
          value: chosen_value
        )
      end

      raw_top_level = first_present(data, *TOP_LEVEL_ID_KEYS.fetch(id_kind))
      chosen_value = normalize_external_id(kind: id_kind, raw_value: raw_top_level)
      return none_signal_payload if chosen_value.blank?

      signal_payload(
        source: SOURCE_METADATA_TOP_LEVEL,
        raw: raw_top_level,
        normalized: chosen_value,
        value: chosen_value
      )
    end

    def metadata_file_path_signal(data)
      raw_path = first_metadata_file_path(data)
      normalized_path = raw_path.to_s.strip.presence
      return none_signal_payload if normalized_path.blank?

      signal_payload(
        source: SOURCE_METADATA_MEDIA_INFO_PARTS_FILE,
        raw: raw_path,
        normalized: normalized_path,
        value: normalized_path
      )
    end

    def first_metadata_file_path(data)
      Array(data["media_info"]).each do |media_info_row|
        next unless media_info_row.is_a?(Hash)

        Array(media_info_row["parts"]).each do |part_row|
          next unless part_row.is_a?(Hash)

          raw_path = part_row["file"]
          next unless raw_path.is_a?(String)

          return raw_path if raw_path.to_s.strip.present?
        end
      end

      nil
    end

    def normalize_external_id(kind:, raw_value:)
      case kind
      when :imdb_id
        raw_value.to_s.strip.presence
      when :tmdb_id, :tvdb_id
        integer_or_nil(raw_value)
      else
        nil
      end
    end

    def metadata_provenance(file_path_signal:, id_signals:)
      {
        endpoint: METADATA_ENDPOINT,
        feed_role: FEED_ROLE_ENRICHMENT,
        source_strength: SOURCE_STRENGTH_STRONG_ENRICHMENT,
        integration_name: integration.name,
        integration_kind: integration.kind,
        integration_id: integration.id,
        signals: {
          file_path: file_path_signal,
          imdb_id: id_signals.fetch(:imdb_id),
          tmdb_id: id_signals.fetch(:tmdb_id),
          tvdb_id: id_signals.fetch(:tvdb_id)
        }
      }
    end

    def discovery_provenance(endpoint:)
      {
        endpoint: endpoint,
        feed_role: FEED_ROLE_DISCOVERY,
        source_strength: SOURCE_STRENGTH_SPARSE_DISCOVERY,
        integration_name: integration.name,
        integration_kind: integration.kind,
        integration_id: integration.id
      }
    end

    def signal_payload(source:, raw:, normalized:, value:)
      {
        source: source,
        raw: raw,
        normalized: normalized,
        value: value
      }
    end

    def none_signal_payload
      signal_payload(source: SOURCE_NONE, raw: nil, normalized: nil, value: nil)
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
