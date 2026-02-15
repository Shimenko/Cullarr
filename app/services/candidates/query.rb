module Candidates
  class Query
    Result = Struct.new(:scope, :filters, :items, :next_cursor, :diagnostics, keyword_init: true)

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
    WATCHED_MATCH_MODES = %w[all any none].freeze
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

    MAPPING_STATUS_CODES = %w[
      verified_path
      verified_external_ids
      verified_tv_structure
      provisional_title_year
      external_source_not_managed
      unresolved
      ambiguous_conflict
    ].freeze
    MAPPING_STATUS_STATES = {
      "verified_path" => "verified",
      "verified_external_ids" => "verified",
      "verified_tv_structure" => "verified",
      "provisional_title_year" => "provisional",
      "external_source_not_managed" => "external",
      "unresolved" => "unresolved",
      "ambiguous_conflict" => "ambiguous"
    }.freeze
    VERIFICATION_ORDER = %w[path external_ids tv_structure title_year].freeze
    VERIFICATION_STEPS = VERIFICATION_ORDER.freeze
    VERIFICATION_OUTCOMES = %w[passed failed skipped not_applicable].freeze
    SELECTED_STEPS = %w[path external_ids tv_structure title_year none].freeze
    RECHECK_OUTCOMES = %w[success skipped failed not_eligible not_attempted].freeze
    CONFLICT_REASONS = %w[
      id_conflicts_with_provisional
      multiple_path_candidates
      multiple_external_id_candidates
      type_mismatch
      plex_rating_key_conflict
      strong_signal_disagreement
    ].freeze
    OWNERSHIP_CLASSIFICATIONS = %w[managed external unknown].freeze
    ROLLUP_REASON_NO_EPISODE_MEDIA_FILES = "no_episode_media_files".freeze
    ROLLUP_REASON_ALL_EPISODES_SINGLE_STATUS = "all_episodes_single_status".freeze
    ROLLUP_REASON_MIXED_EPISODE_STATUSES = "mixed_episode_statuses".freeze
    ROLLUP_STATUS_PRECEDENCE = %w[
      ambiguous_conflict
      unresolved
      provisional_title_year
      external_source_not_managed
      verified_tv_structure
      verified_external_ids
      verified_path
    ].freeze
    ROLLUP_DIAGNOSTICS_MAX_EPISODE_IDS_PER_STATUS = 5

    def initialize(
      scope:,
      saved_view_id: nil,
      plex_user_ids:,
      include_blocked:,
      watched_match_mode: nil,
      cursor:,
      limit:,
      correlation_id: nil,
      actor: nil
    )
      @scope = scope.to_s
      @saved_view_id = saved_view_id
      @plex_user_ids = plex_user_ids
      @include_blocked = include_blocked
      @watched_match_mode = watched_match_mode
      @cursor = cursor
      @limit = limit
      @correlation_id = correlation_id
      @actor = actor
      @guardrail_block_counts = Hash.new(0)
      @resolved_scope = nil
      @resolved_include_blocked = false
      @resolved_watched_match_mode = "none"
    end

    def call
      saved_view = resolve_saved_view!
      @resolved_scope = resolved_scope_for(saved_view)
      validate_scope!(@resolved_scope)
      @resolved_include_blocked = resolved_include_blocked_for(saved_view)
      @resolved_watched_match_mode = resolved_watched_match_mode_for(saved_view)

      selected_user_ids = resolve_selected_user_ids!(saved_view:)
      effective_user_ids = effective_selected_user_ids_for(selected_user_ids)
      result = case @resolved_scope
      when "movie"
        fetch_movie_rows(
          selected_user_ids: effective_user_ids,
          include_blocked: @resolved_include_blocked,
          watched_match_mode: @resolved_watched_match_mode
        )
      when "tv_episode"
        fetch_episode_rows(
          selected_user_ids: effective_user_ids,
          include_blocked: @resolved_include_blocked,
          watched_match_mode: @resolved_watched_match_mode
        )
      when "tv_season"
        fetch_season_rows(
          selected_user_ids: effective_user_ids,
          include_blocked: @resolved_include_blocked,
          watched_match_mode: @resolved_watched_match_mode
        )
      when "tv_show"
        fetch_show_rows(
          selected_user_ids: effective_user_ids,
          include_blocked: @resolved_include_blocked,
          watched_match_mode: @resolved_watched_match_mode
        )
      else
        raise InvalidScopeError, "must be one of: #{SUPPORTED_SCOPES.join(', ')}"
      end

      Result.new(
        scope: @resolved_scope,
        filters: {
          plex_user_ids: selected_user_ids,
          include_blocked: @resolved_include_blocked,
          watched_match_mode: @resolved_watched_match_mode,
          saved_view_id: saved_view&.id
        },
        items: result.fetch(:items),
        next_cursor: result.fetch(:next_cursor),
        diagnostics: result.fetch(:diagnostics).merge(
          content_scope: "arr_managed_only",
          selected_user_count: selected_user_ids.size,
          effective_selected_user_count: effective_user_ids.size
        )
      )
    ensure
      emit_guardrail_events!
    end

    private

    attr_reader :actor, :correlation_id, :cursor, :guardrail_block_counts, :include_blocked, :limit, :plex_user_ids, :saved_view_id, :scope, :watched_match_mode

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
      return [] if ids.nil?

      ids
    end

    def effective_selected_user_ids_for(selected_user_ids)
      return selected_user_ids if selected_user_ids.any?

      PlexUser.order(:id).pluck(:id)
    end

    def resolved_include_blocked_for(saved_view)
      preset_value = saved_view&.filters_json&.dig("include_blocked")
      request_value = parse_optional_boolean(value: include_blocked, field_name: "include_blocked")
      return request_value unless request_value.nil?

      preset_boolean = parse_optional_boolean(value: preset_value, field_name: "include_blocked")
      return preset_boolean unless preset_boolean.nil?

      false
    end

    def resolved_watched_match_mode_for(saved_view)
      preset_value = saved_view&.filters_json&.dig("watched_match_mode")
      request_value = parse_optional_enum(
        value: watched_match_mode,
        field_name: "watched_match_mode",
        allowed_values: WATCHED_MATCH_MODES
      )
      return request_value unless request_value.nil?

      preset_mode = parse_optional_enum(
        value: preset_value,
        field_name: "watched_match_mode",
        allowed_values: WATCHED_MATCH_MODES
      )
      return preset_mode unless preset_mode.nil?

      "none"
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

    def parse_optional_enum(value:, field_name:, allowed_values:)
      return nil if value.nil?

      normalized = value.to_s.strip.downcase
      return normalized if allowed_values.include?(normalized)

      raise InvalidFilterError.new(fields: { field_name => [ "must be one of: #{allowed_values.join(', ')}" ] })
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
      Movie
        .joins(:integration)
        .where(integrations: { kind: "radarr" })
        .includes(:integration, :keep_markers, :watch_stats, media_files: :integration)
        .order(id: :desc)
    end

    def episode_scope
      Episode
        .joins(:integration)
        .where(integrations: { kind: "sonarr" })
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
        .joins(series: :integration)
        .where(integrations: { kind: "sonarr" })
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
        .joins(:integration)
        .where(integrations: { kind: "sonarr" })
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

    def fetch_movie_rows(selected_user_ids:, include_blocked:, watched_match_mode:)
      prefilter = apply_watched_prefilter(
        relation: movie_scope,
        watchable_type: "Movie",
        selected_user_ids:,
        watched_match_mode:
      )
      fetch_rows(
        relation: prefilter.fetch(:relation),
        selected_user_ids:,
        include_blocked:,
        watched_match_mode:,
        watched_prefilter_applied: prefilter.fetch(:applied)
      ) do |movie|
        build_movie_row(movie, selected_user_ids:)
      end
    end

    def fetch_episode_rows(selected_user_ids:, include_blocked:, watched_match_mode:)
      prefilter = apply_watched_prefilter(
        relation: episode_scope,
        watchable_type: "Episode",
        selected_user_ids:,
        watched_match_mode:
      )
      fetch_rows(
        relation: prefilter.fetch(:relation),
        selected_user_ids:,
        include_blocked:,
        watched_match_mode:,
        watched_prefilter_applied: prefilter.fetch(:applied)
      ) do |episode|
        build_episode_row(episode, selected_user_ids:)
      end
    end

    def fetch_season_rows(selected_user_ids:, include_blocked:, watched_match_mode:)
      fetch_rows(
        relation: season_scope,
        selected_user_ids:,
        include_blocked:,
        watched_match_mode:,
        watched_prefilter_applied: false
      ) do |season|
        build_season_row(season, selected_user_ids:)
      end
    end

    def fetch_show_rows(selected_user_ids:, include_blocked:, watched_match_mode:)
      fetch_rows(
        relation: show_scope,
        selected_user_ids:,
        include_blocked:,
        watched_match_mode:,
        watched_prefilter_applied: false
      ) do |series|
        build_show_row(series, selected_user_ids:)
      end
    end

    def apply_watched_prefilter(relation:, watchable_type:, selected_user_ids:, watched_match_mode:)
      if selected_user_ids.empty?
        return { relation: relation, applied: false } if watched_match_mode == "none"
        return { relation: relation.none, applied: true }
      end
      return { relation: relation, applied: false } unless watched_mode == "play_count"

      if watched_match_mode == "none"
        return {
          relation: relation.where.not(id: watched_watchable_ids_subquery(
            watchable_type: watchable_type,
            selected_user_ids: selected_user_ids,
            watched_match_mode: "any"
          )),
          applied: true
        }
      end

      {
        relation: relation.where(id: watched_watchable_ids_subquery(
          watchable_type: watchable_type,
          selected_user_ids: selected_user_ids,
          watched_match_mode: watched_match_mode
        )),
        applied: true
      }
    end

    def watched_watchable_ids_subquery(watchable_type:, selected_user_ids:, watched_match_mode:)
      base_query = WatchStat
        .where(watchable_type:, plex_user_id: selected_user_ids)
        .where(WatchStat.arel_table[:play_count].gteq(1).or(WatchStat.arel_table[:watched].eq(true)))
      return base_query.select(:watchable_id).distinct if watched_match_mode == "any"

      base_query
        .group(:watchable_id)
        .having("COUNT(DISTINCT watch_stats.plex_user_id) = ?", selected_user_ids.size)
        .select(:watchable_id)
    end

    def fetch_rows(relation:, selected_user_ids:, include_blocked:, watched_match_mode:, watched_prefilter_applied:)
      limit_value = parsed_limit
      start_cursor = parsed_cursor
      batch_limit = limit_value * PREFETCH_MULTIPLIER

      items = []
      last_seen_id = nil
      next_upper_bound = start_cursor
      diagnostics = {
        watched_match_mode: watched_match_mode,
        watched_prefilter_applied: watched_prefilter_applied,
        rows_scanned: 0,
        rows_filtered_unwatched: 0,
        rows_filtered_blocked: 0,
        rows_returned: 0
      }

      loop do
        scoped = relation
        scoped = scoped.where(relation.klass.arel_table[:id].lt(next_upper_bound)) if next_upper_bound.present?
        batch = scoped.limit(batch_limit).to_a
        break if batch.empty?

        batch.each do |record|
          row = yield(record)
          diagnostics[:rows_scanned] += 1
          last_seen_id = record.id
          unless watched_match_for_row?(row: row, watched_match_mode: watched_match_mode)
            diagnostics[:rows_filtered_unwatched] += 1
            next
          end
          if !include_blocked && row[:blocker_flags].any?
            track_guardrail_blocks(row[:blocker_flags])
            diagnostics[:rows_filtered_blocked] += 1
            next
          end

          items << row
          diagnostics[:rows_returned] += 1
          break if items.size >= limit_value
        end

        break if items.size >= limit_value
        break if batch.size < batch_limit

        next_upper_bound = batch.last.id
      end

      {
        items: items,
        next_cursor: next_cursor_for(relation:, items:, last_seen_id:, limit_value:),
        diagnostics: diagnostics
      }
    end

    def watched_match_for_row?(row:, watched_match_mode:)
      watched_summary = row.fetch(:watched_summary, {})
      watched_user_count = watched_summary.fetch(:watched_user_count, 0).to_i

      if watched_match_mode == "any"
        watched_user_count.positive?
      elsif watched_match_mode == "none"
        watched_user_count.zero?
      else
        ActiveModel::Type::Boolean.new.cast(watched_summary.fetch(:all_selected_users_watched, false))
      end
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
      mapping_payload = mapping_payload_for_watchable(
        watchable: movie,
        integration: movie.integration
      )

      risk_flags = []
      risk_flags << "multiple_versions" if media_files.size > 1
      risk_flags << "no_plex_mapping" if movie.plex_rating_key.blank?

      blocker_flags = []
      blocker_flags << "path_excluded" if path_excluded?(media_files)
      blocker_flags << "keep_marked" if movie.keep_markers.any?
      blocker_flags << "in_progress_any" if in_progress_any?(watchable: movie, stats_by_user_id:, selected_user_ids:)
      blocker_flags << "ambiguous_mapping" if ambiguous_mapping_for?(movie)
      blocker_flags << "ambiguous_ownership" if ambiguous_ownership?(media_files)

      {
        id: "movie:#{movie.id}",
        candidate_id: "movie:#{movie.id}",
        scope: "movie",
        title: movie.title,
        integration_chips: integration_chips_for(fallback_integration: movie.integration, media_files:),
        reclaimable_bytes: reclaimable_bytes,
        watched_summary: watched_summary,
        mapping_status: mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: mapping_payload.fetch(:mapping_diagnostics),
        risk_flags: risk_flags,
        blocker_flags: blocker_flags,
        reasons: reasons_for(
          added_at: added_timestamp_for_watchable(watchable: movie, fallback_timestamp: movie.created_at),
          watched_summary: watched_summary,
          reclaimable_bytes: reclaimable_bytes
        ),
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
        mapping_status: snapshot[:mapping_status],
        mapping_diagnostics: snapshot[:mapping_diagnostics],
        risk_flags: snapshot[:risk_flags],
        blocker_flags: snapshot[:blocker_flags],
        reasons: reasons_for(
          added_at: added_timestamp_for_watchable(watchable: episode, fallback_timestamp: episode.created_at),
          watched_summary: snapshot[:watched_summary],
          reclaimable_bytes: snapshot[:reclaimable_bytes]
        ),
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
      rollup_mapping_payload = mapping_payload_for_rollup(snapshots:)

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
        mapping_status: rollup_mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: rollup_mapping_payload.fetch(:mapping_diagnostics),
        risk_flags: risk_flags,
        blocker_flags: blocker_flags.uniq,
        reasons: reasons_for(added_at: season.created_at, watched_summary:, reclaimable_bytes:),
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
      rollup_mapping_payload = mapping_payload_for_rollup(snapshots:)

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
        mapping_status: rollup_mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: rollup_mapping_payload.fetch(:mapping_diagnostics),
        risk_flags: risk_flags,
        blocker_flags: blocker_flags.uniq,
        reasons: reasons_for(
          added_at: added_timestamp_for_watchable(watchable: series, fallback_timestamp: series.created_at),
          watched_summary: watched_summary,
          reclaimable_bytes: reclaimable_bytes
        ),
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
      mapping_payload = mapping_payload_for_watchable(
        watchable: episode,
        integration: episode.integration
      )

      risk_flags = []
      risk_flags << "multiple_versions" if media_files.size > 1
      risk_flags << "no_plex_mapping" if episode.plex_rating_key.blank?

      blocker_flags = []
      blocker_flags << "path_excluded" if path_excluded?(media_files)
      blocker_flags << "keep_marked" if keep_marked_episode?(episode)
      blocker_flags << "in_progress_any" if in_progress_any?(watchable: episode, stats_by_user_id:, selected_user_ids:)
      blocker_flags << "ambiguous_mapping" if ambiguous_mapping_for?(episode)
      blocker_flags << "ambiguous_ownership" if ambiguous_ownership?(media_files)

      {
        episode: episode,
        stats_by_user_id: stats_by_user_id,
        watched_summary: watched_summary,
        media_files: media_files,
        mapping_status: mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: mapping_payload.fetch(:mapping_diagnostics),
        mapping_status_code: mapping_payload.fetch(:mapping_status).fetch(:code),
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
      if snapshots.empty?
        return {
          selected_user_count: selected_user_ids.size,
          watched_user_count: 0,
          all_selected_users_watched: false,
          last_watched_at: nil
        }
      end

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

    def reasons_for(added_at:, watched_summary:, reclaimable_bytes:)
      reasons = []
      reasons << "watched_by_all_selected_users" if watched_summary[:all_selected_users_watched]
      reasons << "last_watched_days_ago:#{days_ago(watched_summary[:last_watched_at])}" if watched_summary[:last_watched_at]
      reasons << "added_days_ago:#{days_ago(added_at)}" if added_at
      reasons << format("reclaims_gb:%.2f", reclaimable_bytes.to_f / 1.gigabyte)
      reasons
    end

    def added_timestamp_for_watchable(watchable:, fallback_timestamp:)
      metadata = watchable.respond_to?(:metadata_json) && watchable.metadata_json.is_a?(Hash) ? watchable.metadata_json : {}
      added_timestamp_from_metadata(metadata, key: "arr_added_at") ||
        added_timestamp_from_metadata(metadata, key: "plex_added_at") ||
        fallback_timestamp
    end

    def added_timestamp_from_metadata(metadata, key:)
      raw_value = metadata[key]
      return nil if raw_value.blank?

      return raw_value.to_time if raw_value.respond_to?(:to_time)

      Time.zone.parse(raw_value.to_s)
    rescue ArgumentError
      nil
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

    def mapping_payload_for_watchable(watchable:, integration:)
      status_code = normalized_mapping_status_code_for_watchable(watchable)
      diagnostics = watchable_mapping_diagnostics_for(watchable:, integration:, status_code:)

      {
        mapping_status: {
          code: status_code,
          state: mapping_status_state_for(status_code),
          details: mapping_status_details_for_watchable(status_code:, diagnostics:, watchable:)
        },
        mapping_diagnostics: diagnostics
      }
    end

    def mapping_payload_for_rollup(snapshots:)
      status_by_episode = Hash.new { |hash, key| hash[key] = [] }

      snapshots.each do |snapshot|
        status_code = normalized_mapping_status_code(snapshot[:mapping_status_code])
        status_by_episode[status_code] << snapshot.fetch(:episode).id
      end

      status_counts = status_counts_for_rollup(status_by_episode:)
      non_zero_status_count = status_counts.values.count(&:positive?)
      worst_status_code = worst_rollup_status_code_for(status_counts:)
      rollup_reason = rollup_reason_for(total_episode_count: snapshots.size, non_zero_status_count:)
      worst_status_episode_ids = worst_status_episode_ids_for_rollup(status_by_episode:)
      diagnostics = {
        "kind" => "rollup",
        "schema_version" => "v2_candidate",
        "total_episode_count" => snapshots.size,
        "status_counts" => status_counts,
        "worst_status_code" => worst_status_code,
        "worst_status_episode_ids" => worst_status_episode_ids,
        "id_cap_per_status" => ROLLUP_DIAGNOSTICS_MAX_EPISODE_IDS_PER_STATUS,
        "rollup_reason" => rollup_reason
      }

      {
        mapping_status: {
          code: worst_status_code,
          state: mapping_status_state_for(worst_status_code),
          details: mapping_status_details_for_rollup(
            status_code: worst_status_code,
            diagnostics: diagnostics
          )
        },
        mapping_diagnostics: diagnostics
      }
    end

    def normalized_mapping_status_code_for_watchable(watchable)
      normalized_mapping_status_code(watchable.mapping_status_code)
    end

    def normalized_mapping_status_code(status_code)
      normalized_code = status_code.to_s
      return normalized_code if MAPPING_STATUS_CODES.include?(normalized_code)

      "unresolved"
    end

    def mapping_status_state_for(status_code)
      MAPPING_STATUS_STATES.fetch(status_code.to_s, "unresolved")
    end

    def mapping_status_details_for_watchable(status_code:, diagnostics:, watchable:)
      selected_step = diagnostics.fetch("selected_step", "none")
      ownership = diagnostics.dig("path", "ownership_classification").to_s
      matched_root = diagnostics.dig("path", "matched_managed_root").presence || "none"
      ids = diagnostics.dig("ids", "considered") || {}
      ids_compact = ids.filter { |_key, value| value.present? }.map { |key, value| "#{key}=#{value}" }.join(", ")
      ids_compact = "none" if ids_compact.blank?
      show_source = diagnostics.dig("tv_structure", "show_identity_source").presence || "none"
      season_number = diagnostics.dig("tv_structure", "season_episode_keys", "season_number") || watchable.try(:season)&.season_number
      episode_number = diagnostics.dig("tv_structure", "season_episode_keys", "episode_number") || watchable.try(:episode_number)
      fallback_used = ActiveModel::Type::Boolean.new.cast(diagnostics.dig("tv_structure", "fallback_used"))
      recheck_outcome = diagnostics.dig("promotion_conflict", "recheck_outcome").presence || "not_attempted"
      recheck_reason = diagnostics.dig("promotion_conflict", "recheck_reason").presence || "none"
      conflict_reason = diagnostics.dig("promotion_conflict", "conflict_reason").presence || diagnostics.dig("ids", "conflict_reason").presence || "none"
      winning_source = diagnostics.dig("ids", "winning_source").presence || "none"

      case status_code.to_s
      when "verified_path"
        "Matched by path. ownership=#{ownership}; root=#{matched_root}; selected_step=#{selected_step}."
      when "verified_external_ids"
        "Matched by external IDs. winning_source=#{winning_source}; ids=#{ids_compact}; selected_step=#{selected_step}."
      when "verified_tv_structure"
        "Matched by TV structure. show_source=#{show_source}; S#{season_number || '?'}E#{episode_number || '?'}; fallback_used=#{fallback_used}."
      when "provisional_title_year"
        "Provisional title/year match. recheck_outcome=#{recheck_outcome}; recheck_reason=#{recheck_reason}."
      when "external_source_not_managed"
        "Classified as external source. ownership=external; root=none."
      when "unresolved"
        "Unresolved after verification order. selected_step=#{selected_step}; recheck_outcome=#{recheck_outcome}."
      when "ambiguous_conflict"
        "Ambiguous conflict. reason=#{conflict_reason}; selected_step=#{selected_step}."
      else
        "Mapping status available; open diagnostics for evidence."
      end
    end

    def mapping_status_details_for_rollup(status_code:, diagnostics:)
      non_zero_status_count = diagnostics.fetch("status_counts", {}).values.count(&:positive?)

      "Rollup status=#{status_code}; reason=#{diagnostics.fetch('rollup_reason', ROLLUP_REASON_NO_EPISODE_MEDIA_FILES)}; " \
        "episodes=#{diagnostics.fetch('total_episode_count', 0)}; mixed=#{non_zero_status_count}."
    end

    def watchable_mapping_diagnostics_for(watchable:, integration:, status_code:)
      source = watchable.mapping_diagnostics_json.is_a?(Hash) ? watchable.mapping_diagnostics_json.deep_stringify_keys : {}
      selected_step = selected_step_for_watchable(status_code:, source:)
      path_source = source["path"].is_a?(Hash) ? source["path"] : {}
      signals = source["signals"].is_a?(Hash) ? source["signals"] : {}
      ids_source = source["ids"].is_a?(Hash) ? source["ids"] : {}
      tv_structure_source = source["tv_structure"].is_a?(Hash) ? source["tv_structure"] : {}
      promotion_source = source["promotion_conflict"].is_a?(Hash) ? source["promotion_conflict"] : {}
      provenance_source = source["provenance"].is_a?(Hash) ? source["provenance"] : {}
      ownership = normalize_ownership(path_source["ownership"])
      conflict_reason = normalized_conflict_reason(
        source["conflict_reason"] || ids_source["conflict_reason"] || promotion_source["conflict_reason"]
      )
      season_episode_keys = tv_structure_source["season_episode_keys"].is_a?(Hash) ? tv_structure_source["season_episode_keys"] : {}

      {
        "kind" => "watchable",
        "schema_version" => "v2_candidate",
        "verification_order" => VERIFICATION_ORDER,
        "verification_outcomes" => verification_outcomes_for(
          watchable: watchable,
          selected_step: selected_step
        ),
        "selected_step" => selected_step,
        "provenance" => {
          "integration_name" => integration&.name,
          "integration_kind" => integration&.kind,
          "discovery_endpoint" => provenance_source.dig("discovery", "endpoint"),
          "enrichment_endpoint" => provenance_source.dig("enrichment", "endpoint"),
          "recheck_endpoint" => provenance_source.dig("recheck_enrichment", "endpoint") || provenance_source.dig("recheck_show_enrichment", "endpoint"),
          "raw_values" => {
            "file_path" => signals["file_path"] || path_source["raw_path"],
            "title" => signals["title"] || watchable.try(:title),
            "year" => signals["year"] || watchable.try(:year),
            "plex_guid" => signals["plex_guid"],
            "plex_rating_key" => signals["plex_rating_key"] || watchable.try(:plex_rating_key),
            "imdb_id" => watchable.try(:imdb_id),
            "tmdb_id" => watchable.try(:tmdb_id),
            "tvdb_id" => watchable.try(:tvdb_id),
            "parent_rating_key" => signals["parent_rating_key"],
            "grandparent_rating_key" => signals["grandparent_rating_key"],
            "parent_media_index" => signals["parent_media_index"],
            "media_index" => signals["media_index"]
          },
          "normalized_values" => {
            "canonical_path" => path_source["canonical_path"],
            "normalized_path" => path_source["normalized_path"],
            "ownership_classification" => ownership,
            "matched_managed_root" => path_source["matched_managed_root"],
            "imdb_id" => watchable.try(:imdb_id),
            "tmdb_id" => watchable.try(:tmdb_id),
            "tvdb_id" => watchable.try(:tvdb_id),
            "season_number" => watchable.try(:season)&.season_number,
            "episode_number" => watchable.try(:episode_number)
          }
        },
        "path" => {
          "raw_path" => path_source["raw_path"],
          "normalized_path" => path_source["normalized_path"],
          "ownership_classification" => ownership,
          "matched_managed_root" => path_source["matched_managed_root"]
        },
        "ids" => {
          "considered" => watchable_external_ids_for(watchable),
          "winning_source" => selected_step == "none" ? "none" : selected_step,
          "conflict_reason" => conflict_reason
        },
        "tv_structure" => {
          "show_identity_source" => tv_structure_source["show_identity_source"] || tv_structure_source["show_resolution_status"] || "none",
          "season_episode_keys" => {
            "season_number" => season_episode_keys["season_number"] || watchable.try(:season)&.season_number,
            "episode_number" => season_episode_keys["episode_number"] || watchable.try(:episode_number)
          },
          "fallback_used" => ActiveModel::Type::Boolean.new.cast(tv_structure_source["fallback_used"])
        },
        "promotion_conflict" => {
          "first_pass_status" => promotion_source["first_pass_status"] || source.dig("first_pass", "status_code") || status_code,
          "final_status" => promotion_source["final_status"] || status_code,
          "recheck_outcome" => normalize_recheck_outcome(
            promotion_source["recheck_outcome"] || source.dig("recheck", "state")
          ),
          "recheck_reason" => promotion_source["recheck_reason"] || source.dig("recheck", "reason"),
          "conflict_reason" => conflict_reason
        }
      }
    end

    def selected_step_for_watchable(status_code:, source:)
      explicit_selected_step = source["selected_step"] || source.dig("first_pass", "selected_step")
      normalized_selected_step = normalize_selected_step(explicit_selected_step)
      return normalized_selected_step unless normalized_selected_step == "none"

      case status_code.to_s
      when "verified_path"
        "path"
      when "verified_external_ids"
        "external_ids"
      when "verified_tv_structure"
        "tv_structure"
      when "provisional_title_year"
        "title_year"
      else
        "none"
      end
    end

    def verification_outcomes_for(watchable:, selected_step:)
      outcomes = {
        "path" => "not_applicable",
        "external_ids" => "not_applicable",
        "tv_structure" => "not_applicable",
        "title_year" => "not_applicable"
      }

      applicable_steps = if watchable.is_a?(Movie)
        %w[path external_ids title_year]
      elsif watchable.is_a?(Episode)
        %w[path external_ids tv_structure]
      else
        []
      end
      if applicable_steps.include?(selected_step)
        selected_index = applicable_steps.index(selected_step)
        applicable_steps.each_with_index do |step, index|
          outcomes[step] = if index < selected_index
            "failed"
          elsif index == selected_index
            "passed"
          else
            "skipped"
          end
        end
      else
        applicable_steps.each { |step| outcomes[step] = "failed" }
      end

      outcomes
    end

    def watchable_external_ids_for(watchable)
      {
        "imdb_id" => watchable.try(:imdb_id),
        "tmdb_id" => watchable.try(:tmdb_id),
        "tvdb_id" => watchable.try(:tvdb_id)
      }
    end

    def normalize_selected_step(value)
      selected_step = value.to_s
      return selected_step if SELECTED_STEPS.include?(selected_step)

      "none"
    end

    def normalize_recheck_outcome(value)
      normalized_value = value.to_s
      return normalized_value if RECHECK_OUTCOMES.include?(normalized_value)

      "not_attempted"
    end

    def normalized_conflict_reason(value)
      normalized_value = value.to_s
      return normalized_value if CONFLICT_REASONS.include?(normalized_value)

      nil
    end

    def normalize_ownership(value)
      normalized_value = value.to_s
      return normalized_value if OWNERSHIP_CLASSIFICATIONS.include?(normalized_value)

      "unknown"
    end

    def status_counts_for_rollup(status_by_episode:)
      MAPPING_STATUS_CODES.each_with_object({}) do |status_code, counts|
        counts[status_code] = status_by_episode.fetch(status_code, []).size
      end
    end

    def worst_rollup_status_code_for(status_counts:)
      ROLLUP_STATUS_PRECEDENCE.find { |status_code| status_counts.fetch(status_code, 0).positive? } || "unresolved"
    end

    def rollup_reason_for(total_episode_count:, non_zero_status_count:)
      return ROLLUP_REASON_NO_EPISODE_MEDIA_FILES if total_episode_count.zero?
      return ROLLUP_REASON_ALL_EPISODES_SINGLE_STATUS if non_zero_status_count <= 1

      ROLLUP_REASON_MIXED_EPISODE_STATUSES
    end

    def worst_status_episode_ids_for_rollup(status_by_episode:)
      MAPPING_STATUS_CODES.each_with_object({}) do |status_code, result|
        result[status_code] = status_by_episode
          .fetch(status_code, [])
          .uniq
          .sort
          .first(ROLLUP_DIAGNOSTICS_MAX_EPISODE_IDS_PER_STATUS)
      end
    end

    def watched_mode
      @watched_mode ||= AppSetting.db_value_for("watched_mode").to_s
    end

    def ambiguous_mapping_for?(watchable)
      watchable.mapping_status_code.to_s == "ambiguous_conflict"
    end

    def watched_percent_threshold
      @watched_percent_threshold ||= AppSetting.db_value_for("watched_percent_threshold").to_i
    end

    def in_progress_min_offset_ms
      @in_progress_min_offset_ms ||= AppSetting.db_value_for("in_progress_min_offset_ms").to_i
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
