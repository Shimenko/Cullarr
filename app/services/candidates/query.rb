module Candidates
  class Query
    Result = Struct.new(:scope, :filters, :items, :next_cursor, keyword_init: true)

    class InvalidScopeError < StandardError; end

    class InvalidFilterError < StandardError
      attr_reader :fields

      def initialize(fields:)
        @fields = fields
        super("candidate filters are invalid")
      end
    end

    class SavedViewNotFoundError < StandardError
      attr_reader :saved_view_id

      def initialize(saved_view_id)
        @saved_view_id = saved_view_id
        super("saved view not found")
      end
    end

    SUPPORTED_SCOPES = %w[movie tv_episode tv_season tv_show].freeze
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100
    PREFETCH_MULTIPLIER = 3

    GUARDRAIL_EVENT_BY_FLAG = {
      "path_excluded" => "cullarr.guardrail.blocked_path_excluded",
      "keep_marked" => "cullarr.guardrail.blocked_keep_marker",
      "in_progress_any" => "cullarr.guardrail.blocked_in_progress",
      "ambiguous_mapping" => "cullarr.guardrail.blocked_ambiguous_mapping",
      "ambiguous_ownership" => "cullarr.guardrail.blocked_ambiguous_ownership"
    }.freeze

    def initialize(scope:, saved_view_id: nil, plex_user_ids:, include_blocked:, cursor:, limit:, correlation_id: nil, actor: nil)
      @scope = scope.to_s
      @saved_view_id = saved_view_id
      @plex_user_ids = plex_user_ids
      @include_blocked = include_blocked
      @cursor = cursor
      @limit = limit
      @correlation_id = correlation_id
      @actor = actor
      @guardrail_block_counts = Hash.new(0)
      @resolved_scope = nil
      @resolved_include_blocked = false
    end

    def call
      saved_view = resolve_saved_view!
      @resolved_scope = resolved_scope_for(saved_view)
      validate_scope!(@resolved_scope)
      @resolved_include_blocked = resolved_include_blocked_for(saved_view)

      selected_user_ids = resolve_selected_user_ids!(saved_view:)
      result = case @resolved_scope
      when "movie"
        fetch_movie_rows(selected_user_ids:, include_blocked: @resolved_include_blocked)
      when "tv_episode"
        fetch_episode_rows(selected_user_ids:, include_blocked: @resolved_include_blocked)
      when "tv_season"
        fetch_season_rows(selected_user_ids:, include_blocked: @resolved_include_blocked)
      when "tv_show"
        fetch_show_rows(selected_user_ids:, include_blocked: @resolved_include_blocked)
      else
        raise InvalidScopeError, "must be one of: #{SUPPORTED_SCOPES.join(', ')}"
      end

      Result.new(
        scope: @resolved_scope,
        filters: {
          plex_user_ids: selected_user_ids,
          include_blocked: @resolved_include_blocked,
          saved_view_id: saved_view&.id
        },
        items: result.fetch(:items),
        next_cursor: result.fetch(:next_cursor)
      )
    ensure
      emit_guardrail_events!
    end

    private

    attr_reader :actor, :correlation_id, :cursor, :guardrail_block_counts, :include_blocked, :limit, :plex_user_ids, :saved_view_id, :scope

    def validate_scope!(value)
      return if SUPPORTED_SCOPES.include?(value)

      raise InvalidScopeError, "must be one of: #{SUPPORTED_SCOPES.join(', ')}"
    end

    def resolve_saved_view!
      return nil if saved_view_id.blank?

      parsed_id = Integer(saved_view_id.to_s, exception: false)
      unless parsed_id&.positive?
        raise InvalidFilterError.new(fields: { "saved_view_id" => [ "must be a positive integer" ] })
      end

      SavedView.find(parsed_id)
    rescue ActiveRecord::RecordNotFound
      raise SavedViewNotFoundError.new(saved_view_id.to_i)
    end

    def resolved_scope_for(saved_view)
      raw_scope = scope.presence
      saved_scope = saved_view&.scope
      return saved_scope if raw_scope.blank? && saved_scope.present?
      raise InvalidFilterError.new(fields: { "scope" => [ "is required" ] }) if raw_scope.blank?
      return raw_scope if saved_scope.blank?
      return raw_scope if raw_scope == saved_scope

      raise InvalidFilterError.new(fields: { "scope" => [ "must match saved view scope #{saved_scope}" ] })
    end

    def resolve_selected_user_ids!(saved_view:)
      preset_value = saved_view&.filters_json&.dig("plex_user_ids")
      ids = normalize_optional_positive_integer_array(
        value: plex_user_ids.presence || preset_value,
        field_name: "plex_user_ids"
      )
      return PlexUser.order(:id).pluck(:id) if ids.nil?

      ids
    end

    def resolved_include_blocked_for(saved_view)
      preset_value = saved_view&.filters_json&.dig("include_blocked")
      request_value = parse_optional_boolean(value: include_blocked, field_name: "include_blocked")
      return request_value unless request_value.nil?

      preset_boolean = parse_optional_boolean(value: preset_value, field_name: "include_blocked")
      return preset_boolean unless preset_boolean.nil?

      false
    end

    def parse_optional_boolean(value:, field_name:)
      return nil if value.nil?
      return true if value == true
      return false if value == false

      normalized_value = value.to_s.strip.downcase
      return true if normalized_value == "true"
      return false if normalized_value == "false"

      raise InvalidFilterError.new(fields: { field_name => [ "must be true or false" ] })
    end

    def normalize_optional_positive_integer_array(value:, field_name:)
      return nil if value.nil?

      values = Array(value).map(&:to_s).map(&:strip).reject(&:blank?)
      return [] if values.empty?

      integer_values = values.map { |entry| Integer(entry, exception: false) }
      if integer_values.any?(&:nil?) || integer_values.any? { |entry| entry <= 0 }
        raise InvalidFilterError.new(fields: { field_name => [ "must contain positive integers" ] })
      end

      integer_values.uniq
    end

    def parsed_cursor
      return nil if cursor.blank?

      parsed_value = Integer(cursor.to_s, exception: false)
      return parsed_value if parsed_value.present? && parsed_value.positive?

      raise InvalidFilterError.new(fields: { "cursor" => [ "must be a positive integer" ] })
    end

    def parsed_limit
      return DEFAULT_LIMIT if limit.blank?

      parsed_value = Integer(limit.to_s, exception: false)
      if parsed_value.nil? || parsed_value <= 0
        raise InvalidFilterError.new(fields: { "limit" => [ "must be a positive integer" ] })
      end

      parsed_value.clamp(1, MAX_LIMIT)
    end

    def movie_scope
      Movie.includes(:integration, :keep_markers, :watch_stats, media_files: :integration).order(id: :desc)
    end

    def episode_scope
      Episode
        .includes(
          :integration,
          :watch_stats,
          :keep_markers,
          { season: [ :keep_markers, { series: :keep_markers } ] },
          media_files: :integration
        )
        .order(id: :desc)
    end

    def season_scope
      Season
        .includes(
          { series: :integration },
          :keep_markers,
          {
            episodes: [
              :integration,
              :watch_stats,
              :keep_markers,
              { media_files: :integration }
            ]
          }
        )
        .order(id: :desc)
    end

    def show_scope
      Series
        .includes(
          :integration,
          :keep_markers,
          {
            seasons: [
              :keep_markers,
              {
                episodes: [
                  :integration,
                  :watch_stats,
                  :keep_markers,
                  { media_files: :integration }
                ]
              }
            ]
          }
        )
        .order(id: :desc)
    end

    def fetch_movie_rows(selected_user_ids:, include_blocked:)
      relation = apply_watched_prefilter(
        relation: movie_scope,
        watchable_type: "Movie",
        selected_user_ids:
      )
      fetch_rows(
        relation: relation,
        selected_user_ids:,
        include_blocked:
      ) do |movie|
        build_movie_row(movie, selected_user_ids:)
      end
    end

    def fetch_episode_rows(selected_user_ids:, include_blocked:)
      relation = apply_watched_prefilter(
        relation: episode_scope,
        watchable_type: "Episode",
        selected_user_ids:
      )
      fetch_rows(
        relation: relation,
        selected_user_ids:,
        include_blocked:
      ) do |episode|
        build_episode_row(episode, selected_user_ids:)
      end
    end

    def fetch_season_rows(selected_user_ids:, include_blocked:)
      fetch_rows(
        relation: season_scope,
        selected_user_ids:,
        include_blocked:
      ) do |season|
        build_season_row(season, selected_user_ids:)
      end
    end

    def fetch_show_rows(selected_user_ids:, include_blocked:)
      fetch_rows(
        relation: show_scope,
        selected_user_ids:,
        include_blocked:
      ) do |series|
        build_show_row(series, selected_user_ids:)
      end
    end

    def apply_watched_prefilter(relation:, watchable_type:, selected_user_ids:)
      return relation.none if selected_user_ids.empty?
      return relation unless watched_mode == "play_count"

      relation.where(id: watched_watchable_ids_subquery(watchable_type:, selected_user_ids:))
    end

    def watched_watchable_ids_subquery(watchable_type:, selected_user_ids:)
      WatchStat
        .where(watchable_type:, plex_user_id: selected_user_ids)
        .where(WatchStat.arel_table[:play_count].gteq(1).or(WatchStat.arel_table[:watched].eq(true)))
        .group(:watchable_id)
        .having("COUNT(DISTINCT watch_stats.plex_user_id) = ?", selected_user_ids.size)
        .select(:watchable_id)
    end

    def fetch_rows(relation:, selected_user_ids:, include_blocked:)
      limit_value = parsed_limit
      start_cursor = parsed_cursor
      batch_limit = limit_value * PREFETCH_MULTIPLIER

      items = []
      last_seen_id = nil
      next_upper_bound = start_cursor

      loop do
        scoped = relation
        scoped = scoped.where(relation.klass.arel_table[:id].lt(next_upper_bound)) if next_upper_bound.present?
        batch = scoped.limit(batch_limit).to_a
        break if batch.empty?

        batch.each do |record|
          row = yield(record)
          last_seen_id = record.id
          next unless row.dig(:watched_summary, :all_selected_users_watched)
          if !include_blocked && row[:blocker_flags].any?
            track_guardrail_blocks(row[:blocker_flags])
            next
          end

          items << row
          break if items.size >= limit_value
        end

        break if items.size >= limit_value
        break if batch.size < batch_limit

        next_upper_bound = batch.last.id
      end

      {
        items: items,
        next_cursor: next_cursor_for(relation:, items:, last_seen_id:, limit_value:)
      }
    end

    def next_cursor_for(relation:, items:, last_seen_id:, limit_value:)
      return nil if last_seen_id.nil?
      return nil if items.size < limit_value
      return nil unless relation.where(id: ...last_seen_id).exists?

      last_seen_id
    end

    def build_movie_row(movie, selected_user_ids:)
      stats_by_user_id = movie.watch_stats.index_by(&:plex_user_id)
      watched_summary = watched_summary_for(watchable: movie, stats_by_user_id:, selected_user_ids:)
      media_files = movie.media_files
      reclaimable_bytes = media_files.sum(&:size_bytes)

      risk_flags = []
      risk_flags << "multiple_versions" if media_files.size > 1
      risk_flags << "no_plex_mapping" if movie.plex_rating_key.blank?
      risk_flags << "external_id_mismatch" if flag_enabled?(movie.metadata_json, "external_id_mismatch")
      risk_flags << "low_confidence_mapping" if flag_enabled?(movie.metadata_json, "low_confidence_mapping")

      blocker_flags = []
      blocker_flags << "path_excluded" if path_excluded?(media_files)
      blocker_flags << "keep_marked" if movie.keep_markers.any?
      blocker_flags << "in_progress_any" if in_progress_any?(watchable: movie, stats_by_user_id:, selected_user_ids:)
      blocker_flags << "ambiguous_mapping" if flag_enabled?(movie.metadata_json, "ambiguous_mapping")
      blocker_flags << "ambiguous_ownership" if ambiguous_ownership?(media_files)

      {
        id: "movie:#{movie.id}",
        candidate_id: "movie:#{movie.id}",
        scope: "movie",
        title: movie.title,
        integration_chips: integration_chips_for(fallback_integration: movie.integration, media_files:),
        reclaimable_bytes: reclaimable_bytes,
        watched_summary: watched_summary,
        risk_flags: risk_flags,
        blocker_flags: blocker_flags,
        reasons: reasons_for(created_at: movie.created_at, watched_summary:, reclaimable_bytes:),
        movie_id: movie.id,
        year: movie.year,
        version_count: media_files.size,
        media_file_ids: media_files.map(&:id),
        multi_version_groups: multi_version_groups_for_movie(movie:, media_files:)
      }
    end

    def build_episode_row(episode, selected_user_ids:)
      snapshot = episode_snapshot(episode, selected_user_ids:)

      {
        id: "episode:#{episode.id}",
        candidate_id: "episode:#{episode.id}",
        scope: "tv_episode",
        title: episode_title(episode),
        integration_chips: integration_chips_for(fallback_integration: episode.integration, media_files: snapshot[:media_files]),
        reclaimable_bytes: snapshot[:reclaimable_bytes],
        watched_summary: snapshot[:watched_summary],
        risk_flags: snapshot[:risk_flags],
        blocker_flags: snapshot[:blocker_flags],
        reasons: reasons_for(created_at: episode.created_at, watched_summary: snapshot[:watched_summary], reclaimable_bytes: snapshot[:reclaimable_bytes]),
        episode_id: episode.id,
        series_id: episode.season&.series_id,
        season_number: episode.season&.season_number,
        episode_number: episode.episode_number,
        media_file_ids: snapshot[:media_files].map(&:id),
        multi_version_groups: multi_version_groups_for_episode(episode:, media_files: snapshot[:media_files])
      }
    end

    def build_season_row(season, selected_user_ids:)
      snapshots = episode_snapshots_for(episodes: season.episodes.select { |episode| episode.media_files.any? }, selected_user_ids:)
      media_files = snapshots.flat_map { |snapshot| snapshot[:media_files] }
      watched_summary = watched_summary_for_rollup(snapshots:, selected_user_ids:)
      reclaimable_bytes = media_files.sum(&:size_bytes)
      episode_count = snapshots.size
      eligible_episode_count = snapshots.count { |snapshot| snapshot[:eligible] }

      risk_flags = snapshots.flat_map { |snapshot| snapshot[:risk_flags] }.uniq
      blocker_flags = snapshots.flat_map { |snapshot| snapshot[:blocker_flags] }.uniq
      blocker_flags << "rollup_not_strictly_eligible" if eligible_episode_count != episode_count

      {
        id: "season:#{season.id}",
        candidate_id: "season:#{season.id}",
        scope: "tv_season",
        title: season_title(season),
        integration_chips: integration_chips_for(fallback_integration: season.series.integration, media_files:),
        reclaimable_bytes: reclaimable_bytes,
        watched_summary: watched_summary,
        risk_flags: risk_flags,
        blocker_flags: blocker_flags.uniq,
        reasons: reasons_for(created_at: season.created_at, watched_summary:, reclaimable_bytes:),
        season_id: season.id,
        series_id: season.series_id,
        season_number: season.season_number,
        episode_count: episode_count,
        eligible_episode_count: eligible_episode_count,
        media_file_ids: media_files.map(&:id),
        multi_version_groups: multi_version_groups_for_snapshots(snapshots:)
      }
    end

    def build_show_row(series, selected_user_ids:)
      episodes = series.seasons.flat_map(&:episodes).select { |episode| episode.media_files.any? }
      snapshots = episode_snapshots_for(episodes:, selected_user_ids:)
      media_files = snapshots.flat_map { |snapshot| snapshot[:media_files] }
      watched_summary = watched_summary_for_rollup(snapshots:, selected_user_ids:)
      reclaimable_bytes = media_files.sum(&:size_bytes)
      episode_count = snapshots.size
      eligible_episode_count = snapshots.count { |snapshot| snapshot[:eligible] }

      risk_flags = snapshots.flat_map { |snapshot| snapshot[:risk_flags] }.uniq
      blocker_flags = snapshots.flat_map { |snapshot| snapshot[:blocker_flags] }.uniq
      blocker_flags << "rollup_not_strictly_eligible" if eligible_episode_count != episode_count

      {
        id: "show:#{series.id}",
        candidate_id: "show:#{series.id}",
        scope: "tv_show",
        title: series.title,
        integration_chips: integration_chips_for(fallback_integration: series.integration, media_files:),
        reclaimable_bytes: reclaimable_bytes,
        watched_summary: watched_summary,
        risk_flags: risk_flags,
        blocker_flags: blocker_flags.uniq,
        reasons: reasons_for(created_at: series.created_at, watched_summary:, reclaimable_bytes:),
        series_id: series.id,
        season_count: series.seasons.size,
        episode_count: episode_count,
        eligible_episode_count: eligible_episode_count,
        media_file_ids: media_files.map(&:id),
        multi_version_groups: multi_version_groups_for_snapshots(snapshots:)
      }
    end

    def multi_version_groups_for_movie(movie:, media_files:)
      return {} unless media_files.size > 1

      { "movie:#{movie.id}" => media_files.map(&:id) }
    end

    def multi_version_groups_for_episode(episode:, media_files:)
      return {} unless media_files.size > 1

      { "episode:#{episode.id}" => media_files.map(&:id) }
    end

    def multi_version_groups_for_snapshots(snapshots:)
      snapshots.each_with_object({}) do |snapshot, groups|
        media_file_ids = snapshot.fetch(:media_files).map(&:id)
        next if media_file_ids.size <= 1

        groups["episode:#{snapshot.fetch(:episode).id}"] = media_file_ids
      end
    end

    def episode_snapshots_for(episodes:, selected_user_ids:)
      episodes.map { |episode| episode_snapshot(episode, selected_user_ids:) }
    end

    def episode_snapshot(episode, selected_user_ids:)
      stats_by_user_id = episode.watch_stats.index_by(&:plex_user_id)
      watched_summary = watched_summary_for(watchable: episode, stats_by_user_id:, selected_user_ids:)
      media_files = episode.media_files
      reclaimable_bytes = media_files.sum(&:size_bytes)

      risk_flags = []
      risk_flags << "multiple_versions" if media_files.size > 1
      risk_flags << "no_plex_mapping" if episode.plex_rating_key.blank?
      risk_flags << "external_id_mismatch" if flag_enabled?(episode.metadata_json, "external_id_mismatch")
      risk_flags << "low_confidence_mapping" if flag_enabled?(episode.metadata_json, "low_confidence_mapping")

      blocker_flags = []
      blocker_flags << "path_excluded" if path_excluded?(media_files)
      blocker_flags << "keep_marked" if keep_marked_episode?(episode)
      blocker_flags << "in_progress_any" if in_progress_any?(watchable: episode, stats_by_user_id:, selected_user_ids:)
      blocker_flags << "ambiguous_mapping" if flag_enabled?(episode.metadata_json, "ambiguous_mapping")
      blocker_flags << "ambiguous_ownership" if ambiguous_ownership?(media_files)

      {
        episode: episode,
        stats_by_user_id: stats_by_user_id,
        watched_summary: watched_summary,
        media_files: media_files,
        reclaimable_bytes: reclaimable_bytes,
        risk_flags: risk_flags.uniq,
        blocker_flags: blocker_flags.uniq,
        eligible: watched_summary[:all_selected_users_watched] && blocker_flags.empty?
      }
    end

    def season_title(season)
      [ season.series&.title, "Season #{season.season_number}" ].compact.join(" - ")
    end

    def episode_title(episode)
      return episode.title if episode.title.present?

      series_title = episode.season&.series&.title
      season_number = episode.season&.season_number
      [ series_title, "S#{season_number}E#{episode.episode_number}" ].compact.join(" ")
    end

    def keep_marked_episode?(episode)
      episode.keep_markers.any? ||
        episode.season&.keep_markers&.any? ||
        episode.season&.series&.keep_markers&.any?
    end

    def watched_summary_for(watchable:, stats_by_user_id:, selected_user_ids:)
      watched_user_count = selected_user_ids.count do |plex_user_id|
        watched_for_user?(
          watch_stat: stats_by_user_id[plex_user_id],
          duration_ms: watchable.duration_ms
        )
      end

      {
        selected_user_count: selected_user_ids.size,
        watched_user_count: watched_user_count,
        all_selected_users_watched: selected_user_ids.any? && watched_user_count == selected_user_ids.size,
        last_watched_at: stats_by_user_id.values.map(&:last_watched_at).compact.max
      }
    end

    def watched_summary_for_rollup(snapshots:, selected_user_ids:)
      watched_user_count = selected_user_ids.count do |plex_user_id|
        snapshots.all? do |snapshot|
          watched_for_user?(
            watch_stat: snapshot[:stats_by_user_id][plex_user_id],
            duration_ms: snapshot[:episode].duration_ms
          )
        end
      end

      {
        selected_user_count: selected_user_ids.size,
        watched_user_count: watched_user_count,
        all_selected_users_watched: snapshots.any? && watched_user_count == selected_user_ids.size,
        last_watched_at: snapshots.map { |snapshot| snapshot.dig(:watched_summary, :last_watched_at) }.compact.max
      }
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

    def in_progress_any?(watchable:, stats_by_user_id:, selected_user_ids:)
      selected_user_ids.any? do |plex_user_id|
        watch_stat = stats_by_user_id[plex_user_id]
        in_progress_for_user?(watch_stat:, duration_ms: watchable.duration_ms)
      end
    end

    def in_progress_for_user?(watch_stat:, duration_ms:)
      return false if watch_stat.nil?
      return true if watch_stat.in_progress?

      watch_stat.max_view_offset_ms.to_i >= in_progress_min_offset_ms &&
        !watched_for_user?(watch_stat:, duration_ms:)
    end

    def reasons_for(created_at:, watched_summary:, reclaimable_bytes:)
      reasons = []
      reasons << "watched_by_all_selected_users" if watched_summary[:all_selected_users_watched]
      reasons << "last_watched_days_ago:#{days_ago(watched_summary[:last_watched_at])}" if watched_summary[:last_watched_at]
      reasons << "added_days_ago:#{days_ago(created_at)}" if created_at
      reasons << format("reclaims_gb:%.2f", reclaimable_bytes.to_f / 1.gigabyte)
      reasons
    end

    def days_ago(timestamp)
      ((Time.current - timestamp) / 1.day).floor
    end

    def path_excluded?(media_files)
      media_files.any? { |media_file| path_excluded_for_path?(media_file.path_canonical) }
    end

    def path_excluded_for_path?(path)
      normalized_path = path.to_s

      exclusion_prefixes.any? do |prefix|
        prefix == "/" || normalized_path == prefix || normalized_path.start_with?("#{prefix}/")
      end
    end

    def ambiguous_ownership?(media_files)
      paths = media_files.map(&:path_canonical).compact.uniq
      return false if paths.empty?

      populate_path_owner_counts!(paths)
      paths.any? { |path| @path_owner_counts.fetch(path, 0) > 1 }
    end

    def populate_path_owner_counts!(paths)
      @path_owner_counts ||= {}
      missing_paths = paths - @path_owner_counts.keys
      return if missing_paths.empty?

      counts = MediaFile.where(path_canonical: missing_paths).group(:path_canonical).distinct.count(:integration_id)
      missing_paths.each { |path| @path_owner_counts[path] = counts.fetch(path, 0) }
    end

    def exclusion_prefixes
      @exclusion_prefixes ||= PathExclusion.where(enabled: true).pluck(:path_prefix)
    end

    def integration_chips_for(fallback_integration:, media_files:)
      chips = media_files.filter_map { |media_file| media_file.integration&.name }.uniq
      chips = [ fallback_integration.name ] if chips.empty? && fallback_integration.present?
      chips
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

    def flag_enabled?(flags_hash, key)
      ActiveModel::Type::Boolean.new.cast(flags_hash.is_a?(Hash) ? flags_hash[key] : false)
    end

    def track_guardrail_blocks(blocker_flags)
      blocker_flags.each do |flag|
        next unless GUARDRAIL_EVENT_BY_FLAG.key?(flag)

        guardrail_block_counts[flag] += 1
      end
    end

    def emit_guardrail_events!
      return if guardrail_block_counts.empty?

      guardrail_block_counts.each do |flag, blocked_count|
        event_name = GUARDRAIL_EVENT_BY_FLAG.fetch(flag)
        AuditEvents::Recorder.record_without_subject!(
          event_name: event_name,
          correlation_id: correlation_id.presence || SecureRandom.uuid,
          actor: actor,
          payload: {
            scope: @resolved_scope,
            blocker_flag: flag,
            blocked_count: blocked_count,
            include_blocked: @resolved_include_blocked
          }
        )
      end
    end
  end
end
