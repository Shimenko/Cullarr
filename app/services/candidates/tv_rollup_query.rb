module Candidates
  class TvRollupQuery
    def initialize(query:, scope:, relation:, selected_user_ids:, include_blocked:, watched_match_mode:)
      @query = query
      @scope = scope
      @relation = relation
      @selected_user_ids = selected_user_ids
      @include_blocked = include_blocked
      @watched_match_mode = watched_match_mode
    end

    def call
      limit_value = query.send(:parsed_limit)
      last_seen_id = nil
      next_upper_bound = query.send(:parsed_cursor)
      items = []
      diagnostics = base_diagnostics

      loop do
        batch = parent_batch_for(next_upper_bound:, limit_value:)
        break if batch.empty?

        rows_by_parent_id = rows_by_parent_id_for(batch)

        batch.each do |parent|
          row = rows_by_parent_id.fetch(parent.id)
          diagnostics[:rows_scanned] += 1
          last_seen_id = parent.id

          unless query.send(:watched_match_for_row?, row:, watched_match_mode:)
            diagnostics[:rows_filtered_unwatched] += 1
            next
          end

          if !include_blocked && row[:blocker_flags].any?
            query.send(:track_guardrail_blocks, row[:blocker_flags])
            diagnostics[:rows_filtered_blocked] += 1
            next
          end

          items << row
          diagnostics[:rows_returned] += 1
          break if items.size >= limit_value
        end

        break if items.size >= limit_value
        break if batch.size < batch_limit(limit_value)

        next_upper_bound = batch.last.id
      end

      {
        items: items,
        next_cursor: query.send(
          :next_cursor_for,
          relation: relation,
          items: items,
          last_seen_id: last_seen_id,
          limit_value: limit_value
        ),
        diagnostics: diagnostics
      }
    end

    private

    attr_reader :include_blocked, :query, :relation, :scope, :selected_user_ids, :watched_match_mode

    def base_diagnostics
      {
        watched_match_mode: watched_match_mode,
        watched_prefilter_applied: false,
        rows_scanned: 0,
        rows_filtered_unwatched: 0,
        rows_filtered_blocked: 0,
        rows_returned: 0
      }
    end

    def parent_batch_for(next_upper_bound:, limit_value:)
      scoped = relation
      if next_upper_bound.present?
        scoped = scoped.where(relation.klass.arel_table[:id].lt(next_upper_bound))
      end

      scoped.limit(batch_limit(limit_value)).to_a
    end

    def batch_limit(limit_value)
      limit_value * Candidates::Query::PREFETCH_MULTIPLIER
    end

    def rows_by_parent_id_for(parents)
      scope == "tv_season" ? season_rows_by_id(parents) : show_rows_by_id(parents)
    end

    def season_rows_by_id(seasons)
      batch = build_batch(
        seasons: seasons,
        series_by_id: seasons.each_with_object({}) do |season, result|
          result[season.series_id] = season.series
        end
      )

      seasons.each_with_object({}) do |season, rows|
        season_episodes = batch[:episodes_by_season_id].fetch(season.id, [])
        rows[season.id] = build_season_row(
          season,
          episodes: season_episodes.select { |episode| batch[:media_files_by_episode_id].fetch(episode.id, []).any? },
          batch:
        )
      end
    end

    def show_rows_by_id(series_batch)
      seasons = Season.where(series_id: series_batch.map(&:id)).order(:id).to_a
      series_by_id = series_batch.index_by(&:id)
      seasons.each do |season|
        series = series_by_id.fetch(season.series_id)
        season.association(:series).target = series
        season.association(:series).loaded!
      end

      batch = build_batch(seasons:, series_by_id:)

      series_batch.each_with_object({}) do |series, rows|
        show_seasons = batch[:seasons_by_series_id].fetch(series.id, [])
        show_episodes = show_seasons.flat_map { |season| batch[:episodes_by_season_id].fetch(season.id, []) }
        rows[series.id] = build_show_row(
          series,
          seasons: show_seasons,
          episodes: show_episodes.select { |episode| batch[:media_files_by_episode_id].fetch(episode.id, []).any? },
          batch:
        )
      end
    end

    def build_batch(seasons:, series_by_id:)
      season_ids = seasons.map(&:id)
      episodes = Episode.where(season_id: season_ids).order(:id).to_a
      seasons_by_id = seasons.index_by(&:id)

      episodes.each do |episode|
        season = seasons_by_id.fetch(episode.season_id)
        episode.association(:season).target = season
        episode.association(:season).loaded!
      end

      episode_ids = episodes.map(&:id)
      media_files = MediaFile
        .where(attachable_type: "Episode", attachable_id: episode_ids)
        .order(:id)
        .to_a
      media_files_by_episode_id = media_files.group_by(&:attachable_id)

      watch_stats = if episode_ids.any? && selected_user_ids.any?
        WatchStat
          .where(watchable_type: "Episode", watchable_id: episode_ids, plex_user_id: selected_user_ids)
          .order(:id)
          .to_a
      else
        []
      end
      watch_stats_by_episode_id = watch_stats.group_by(&:watchable_id)
      last_watched_at_by_episode_id = if episode_ids.any?
        WatchStat
          .where(watchable_type: "Episode", watchable_id: episode_ids)
          .group(:watchable_id)
          .maximum(:last_watched_at)
      else
        {}
      end

      keep_marker_flags = load_keep_marker_flags(
        episode_ids: episode_ids,
        season_ids: season_ids,
        series_ids: series_by_id.keys
      )

      integrations_by_id = build_integrations_by_id(
        series_by_id:,
        episodes:,
        media_files:
      )
      media_files.each do |media_file|
        media_file.association(:integration).target = integrations_by_id[media_file.integration_id]
        media_file.association(:integration).loaded!
      end

      query.send(:populate_path_owner_counts!, media_files.map(&:path_canonical).compact.uniq)

      {
        seasons_by_id: seasons_by_id,
        seasons_by_series_id: seasons.group_by(&:series_id),
        episodes_by_season_id: episodes.group_by(&:season_id),
        media_files_by_episode_id: media_files_by_episode_id,
        watch_stats_by_episode_id: watch_stats_by_episode_id,
        last_watched_at_by_episode_id: last_watched_at_by_episode_id,
        keep_marker_flags: keep_marker_flags,
        integrations_by_id: integrations_by_id
      }
    end

    def build_integrations_by_id(series_by_id:, episodes:, media_files:)
      integrations_by_id = series_by_id.each_with_object({}) do |(_series_id, series), result|
        integration = series.integration
        result[integration.id] = integration if integration.present?
      end

      missing_ids = (episodes.map(&:integration_id) + media_files.map(&:integration_id)).compact.uniq - integrations_by_id.keys
      return integrations_by_id if missing_ids.empty?

      integrations_by_id.merge!(Integration.where(id: missing_ids).index_by(&:id))
      integrations_by_id
    end

    def load_keep_marker_flags(episode_ids:, season_ids:, series_ids:)
      clauses = []
      binds = []

      if episode_ids.any?
        clauses << "(keepable_type = ? AND keepable_id IN (?))"
        binds << "Episode" << episode_ids
      end

      if season_ids.any?
        clauses << "(keepable_type = ? AND keepable_id IN (?))"
        binds << "Season" << season_ids
      end

      if series_ids.any?
        clauses << "(keepable_type = ? AND keepable_id IN (?))"
        binds << "Series" << series_ids
      end

      markers = if clauses.empty?
        []
      else
        KeepMarker.where([ clauses.join(" OR "), *binds ]).to_a
      end

      markers.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |marker, flags|
        flags[marker.keepable_type][marker.keepable_id] = true
      end
    end

    def build_season_row(season, episodes:, batch:)
      snapshots = episodes.map { |episode| snapshot_for(episode, batch:) }
      media_files = snapshots.flat_map { |snapshot| snapshot[:media_files] }
      watched_summary = query.send(:watched_summary_for_rollup, snapshots:, selected_user_ids:)
      reclaimable_bytes = media_files.sum(&:size_bytes)
      episode_count = snapshots.size
      eligible_episode_count = snapshots.count { |snapshot| snapshot[:eligible] }
      rollup_mapping_payload = query.send(:mapping_payload_for_rollup, snapshots:)

      blocker_flags = snapshots.flat_map { |snapshot| snapshot[:blocker_flags] }.uniq
      blocker_flags << "rollup_not_strictly_eligible" if eligible_episode_count != episode_count

      {
        id: "season:#{season.id}",
        candidate_id: "season:#{season.id}",
        scope: "tv_season",
        title: query.send(:season_title, season),
        integration_chips: query.send(
          :integration_chips_for,
          fallback_integration: season.series.integration,
          media_files: media_files
        ),
        reclaimable_bytes: reclaimable_bytes,
        watched_summary: watched_summary,
        mapping_status: rollup_mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: rollup_mapping_payload.fetch(:mapping_diagnostics),
        risk_flags: snapshots.flat_map { |snapshot| snapshot[:risk_flags] }.uniq,
        blocker_flags: blocker_flags.uniq,
        reasons: query.send(:reasons_for, added_at: season.created_at, watched_summary:, reclaimable_bytes:),
        season_id: season.id,
        series_id: season.series_id,
        season_number: season.season_number,
        episode_count: episode_count,
        eligible_episode_count: eligible_episode_count,
        media_file_ids: media_files.map(&:id),
        multi_version_groups: query.send(:multi_version_groups_for_snapshots, snapshots:)
      }
    end

    def build_show_row(series, seasons:, episodes:, batch:)
      snapshots = episodes.map { |episode| snapshot_for(episode, batch:) }
      media_files = snapshots.flat_map { |snapshot| snapshot[:media_files] }
      watched_summary = query.send(:watched_summary_for_rollup, snapshots:, selected_user_ids:)
      reclaimable_bytes = media_files.sum(&:size_bytes)
      episode_count = snapshots.size
      eligible_episode_count = snapshots.count { |snapshot| snapshot[:eligible] }
      rollup_mapping_payload = query.send(:mapping_payload_for_rollup, snapshots:)

      blocker_flags = snapshots.flat_map { |snapshot| snapshot[:blocker_flags] }.uniq
      blocker_flags << "rollup_not_strictly_eligible" if eligible_episode_count != episode_count

      {
        id: "show:#{series.id}",
        candidate_id: "show:#{series.id}",
        scope: "tv_show",
        title: series.title,
        integration_chips: query.send(
          :integration_chips_for,
          fallback_integration: series.integration,
          media_files: media_files
        ),
        reclaimable_bytes: reclaimable_bytes,
        watched_summary: watched_summary,
        mapping_status: rollup_mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: rollup_mapping_payload.fetch(:mapping_diagnostics),
        risk_flags: snapshots.flat_map { |snapshot| snapshot[:risk_flags] }.uniq,
        blocker_flags: blocker_flags.uniq,
        reasons: query.send(
          :reasons_for,
          added_at: query.send(:added_timestamp_for_watchable, watchable: series, fallback_timestamp: series.created_at),
          watched_summary: watched_summary,
          reclaimable_bytes: reclaimable_bytes
        ),
        series_id: series.id,
        season_count: seasons.size,
        episode_count: episode_count,
        eligible_episode_count: eligible_episode_count,
        media_file_ids: media_files.map(&:id),
        multi_version_groups: query.send(:multi_version_groups_for_snapshots, snapshots:)
      }
    end

    def snapshot_for(episode, batch:)
      stats_by_user_id = batch[:watch_stats_by_episode_id].fetch(episode.id, []).index_by(&:plex_user_id)
      watched_summary = query.send(
        :watched_summary_for,
        watchable: episode,
        stats_by_user_id: stats_by_user_id,
        selected_user_ids: selected_user_ids
      ).merge(last_watched_at: batch[:last_watched_at_by_episode_id][episode.id])
      media_files = batch[:media_files_by_episode_id].fetch(episode.id, [])
      mapping_payload = query.send(
        :mapping_payload_for_watchable,
        watchable: episode,
        integration: batch[:integrations_by_id][episode.integration_id]
      )
      blocker_flags = []
      blocker_flags << "path_excluded" if query.send(:path_excluded?, media_files)
      blocker_flags << "keep_marked" if keep_marked_episode?(episode, batch[:keep_marker_flags])
      blocker_flags << "in_progress_any" if query.send(
        :in_progress_any?,
        watchable: episode,
        stats_by_user_id: stats_by_user_id,
        selected_user_ids: selected_user_ids
      )
      blocker_flags << "ambiguous_mapping" if query.send(:ambiguous_mapping_for?, episode)
      blocker_flags << "ambiguous_ownership" if query.send(:ambiguous_ownership?, media_files)

      risk_flags = []
      risk_flags << "multiple_versions" if media_files.size > 1
      risk_flags << "no_plex_mapping" if episode.plex_rating_key.blank?

      {
        episode: episode,
        stats_by_user_id: stats_by_user_id,
        watched_summary: watched_summary,
        media_files: media_files,
        mapping_status: mapping_payload.fetch(:mapping_status),
        mapping_diagnostics: mapping_payload.fetch(:mapping_diagnostics),
        mapping_status_code: mapping_payload.fetch(:mapping_status).fetch(:code),
        reclaimable_bytes: media_files.sum(&:size_bytes),
        risk_flags: risk_flags.uniq,
        blocker_flags: blocker_flags.uniq,
        eligible: watched_summary[:all_selected_users_watched] && blocker_flags.empty?
      }
    end

    def keep_marked_episode?(episode, keep_marker_flags)
      keep_marker_flags.fetch("Episode", {}).key?(episode.id) ||
        keep_marker_flags.fetch("Season", {}).key?(episode.season_id) ||
        keep_marker_flags.fetch("Series", {}).key?(episode.season.series_id)
    end
  end
end
