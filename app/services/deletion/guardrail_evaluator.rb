module Deletion
  class GuardrailEvaluator
    ERROR_CODE_BY_FLAG = {
      "path_excluded" => "guardrail_path_excluded",
      "keep_marked" => "guardrail_keep_marker",
      "in_progress_any" => "guardrail_in_progress",
      "ambiguous_mapping" => "guardrail_ambiguous_mapping",
      "ambiguous_ownership" => "guardrail_ambiguous_ownership"
    }.freeze

    Result = Struct.new(:blocker_flags, :error_codes, keyword_init: true) do
      def blocked?
        blocker_flags.any?
      end
    end

    def initialize(selected_plex_user_ids:)
      @selected_plex_user_ids = selected_plex_user_ids
    end

    def call(media_file:)
      blockers = []
      blockers << "path_excluded" if path_excluded?(media_file.path_canonical)
      blockers << "keep_marked" if keep_marked?(media_file.attachable)
      blockers << "in_progress_any" if in_progress_any?(media_file.attachable)
      blockers << "ambiguous_mapping" if ambiguous_mapping?(media_file.attachable)
      blockers << "ambiguous_ownership" if ambiguous_ownership?(media_file.path_canonical)
      blockers.uniq!

      Result.new(
        blocker_flags: blockers,
        error_codes: blockers.map { |flag| ERROR_CODE_BY_FLAG.fetch(flag) }
      )
    end

    private

    attr_reader :selected_plex_user_ids

    def keep_marked?(attachable)
      case attachable
      when Movie
        attachable.keep_markers.any?
      when Episode
        attachable.keep_markers.any? ||
          attachable.season&.keep_markers&.any? ||
          attachable.season&.series&.keep_markers&.any?
      else
        false
      end
    end

    def in_progress_any?(attachable)
      stats_by_user_id = attachable.watch_stats.where(plex_user_id: selected_plex_user_ids).index_by(&:plex_user_id)

      selected_plex_user_ids.any? do |plex_user_id|
        in_progress_for_user?(watch_stat: stats_by_user_id[plex_user_id], duration_ms: attachable.duration_ms)
      end
    end

    def in_progress_for_user?(watch_stat:, duration_ms:)
      return false if watch_stat.nil?
      return true if watch_stat.in_progress?

      watch_stat.max_view_offset_ms.to_i >= in_progress_min_offset_ms &&
        !watched_for_user?(watch_stat:, duration_ms:)
    end

    def watched_for_user?(watch_stat:, duration_ms:)
      return false if watch_stat.nil?

      if watched_mode == "percent"
        duration_value = duration_ms.to_i
        if duration_value.positive?
          percent = (watch_stat.max_view_offset_ms.to_f / duration_value) * 100
          return true if percent >= watched_percent_threshold
        end
      end

      watch_stat.play_count.to_i >= 1 || ActiveModel::Type::Boolean.new.cast(watch_stat.watched)
    end

    def ambiguous_mapping?(attachable)
      metadata = attachable.respond_to?(:metadata_json) ? attachable.metadata_json : {}
      ActiveModel::Type::Boolean.new.cast(metadata.is_a?(Hash) ? metadata["ambiguous_mapping"] : false)
    end

    def ambiguous_ownership?(path_canonical)
      return false if path_canonical.blank?

      path_owner_count(path_canonical) > 1
    end

    def path_excluded?(path)
      normalized_path = path.to_s

      exclusion_prefixes.any? do |prefix|
        prefix == "/" || normalized_path == prefix || normalized_path.start_with?("#{prefix}/")
      end
    end

    def path_owner_count(path_canonical)
      @path_owner_counts ||= {}
      return @path_owner_counts[path_canonical] if @path_owner_counts.key?(path_canonical)

      count = MediaFile.where(path_canonical: path_canonical).distinct.count(:integration_id)
      @path_owner_counts[path_canonical] = count
    end

    def exclusion_prefixes
      @exclusion_prefixes ||= PathExclusion.where(enabled: true).pluck(:path_prefix)
    end

    def watched_mode
      @watched_mode ||= AppSetting.db_value_for("watched_mode").to_s
    end

    def watched_percent_threshold
      @watched_percent_threshold ||= AppSetting.db_value_for("watched_percent_threshold").to_i
    end

    def in_progress_min_offset_ms
      @in_progress_min_offset_ms ||= AppSetting.db_value_for("in_progress_min_offset_ms").to_i
    end
  end
end
