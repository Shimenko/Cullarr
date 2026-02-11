require "set"

module Sync
  class TautulliHistorySync
    AMBIGUOUS_WATCHABLE = Object.new.freeze

    HISTORY_OVERLAP_ROWS = 100
    RECENT_HISTORY_MEMORY = 1000
    HISTORY_PROCESS_BATCH_SIZE = 1000

    def initialize(sync_run:, correlation_id:, phase_progress: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_progress = phase_progress
    end

    def call
      counts = {
        integrations: 0,
        rows_fetched: 0,
        rows_processed: 0,
        rows_skipped: 0,
        rows_skipped_overlap: 0,
        rows_skipped_missing_user: 0,
        rows_skipped_missing_watchable: 0,
        rows_invalid: 0,
        rows_ambiguous: 0,
        watch_stats_upserted: 0,
        metadata_lookup_attempted: 0,
        metadata_lookup_failed: 0,
        watchables_backfilled: 0,
        history_state_updates: 0,
        history_state_skipped: 0,
        degraded_zero_processed: 0
      }

      log_info("sync_phase_worker_started phase=tautulli_history")
      Integration.tautulli.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::TautulliAdapter.new(integration:)
        page_size = integration.tautulli_history_page_size
        metadata_workers = integration.tautulli_metadata_workers_resolved
        reset_metadata_caches!
        rows = incremental_history_rows(adapter:, integration:)
        counts[:rows_fetched] += rows[:fetched]
        counts[:rows_skipped_overlap] += rows[:skipped_overlap]
        phase_progress&.advance!(rows[:skipped])
        upsert_result = upsert_watch_stats!(rows[:process], integration:)
        counts[:rows_processed] += upsert_result[:rows_processed]
        counts[:rows_invalid] += rows[:invalid]
        counts[:rows_skipped_missing_user] += upsert_result[:rows_skipped_missing_user]
        counts[:rows_skipped_missing_watchable] += upsert_result[:rows_skipped_missing_watchable]
        counts[:rows_skipped] += rows[:invalid] + rows[:skipped_overlap] + upsert_result[:rows_skipped]
        counts[:rows_ambiguous] += upsert_result[:rows_ambiguous]
        counts[:watch_stats_upserted] += upsert_result[:watch_stats_upserted]
        counts[:metadata_lookup_attempted] += upsert_result[:metadata_lookup_attempted]
        counts[:metadata_lookup_failed] += upsert_result[:metadata_lookup_failed]
        counts[:watchables_backfilled] += upsert_result[:watchables_backfilled]
        if rows[:fetched].positive? && upsert_result[:rows_processed].zero?
          counts[:degraded_zero_processed] += 1
          log_info(
            "sync_phase_worker_zero_processed phase=tautulli_history integration_id=#{integration.id} " \
            "rows_fetched=#{rows[:fetched]} rows_skipped_missing_watchable=#{upsert_result[:rows_skipped_missing_watchable]} " \
            "metadata_lookup_attempted=#{upsert_result[:metadata_lookup_attempted]} " \
            "metadata_lookup_failed=#{upsert_result[:metadata_lookup_failed]}"
          )
        end

        persisted = persist_history_state!(
          integration: integration,
          state: next_history_state(
            sync_state: rows[:sync_state],
            max_seen_history_id: rows[:max_seen_history_id],
            processed_history_ids: upsert_result[:processed_history_ids]
          )
        )
        if persisted
          counts[:history_state_updates] += 1
        else
          counts[:history_state_skipped] += 1
        end

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_history integration_id=#{integration.id} " \
          "page_size=#{page_size} " \
          "metadata_workers=#{metadata_workers} " \
          "rows_fetched=#{counts[:rows_fetched]} rows_processed=#{counts[:rows_processed]} " \
          "rows_invalid=#{counts[:rows_invalid]} " \
          "rows_skipped=#{counts[:rows_skipped]} rows_skipped_overlap=#{counts[:rows_skipped_overlap]} " \
          "rows_skipped_missing_user=#{counts[:rows_skipped_missing_user]} " \
          "rows_skipped_missing_watchable=#{counts[:rows_skipped_missing_watchable]} " \
          "rows_ambiguous=#{counts[:rows_ambiguous]} " \
          "watch_stats_upserted=#{counts[:watch_stats_upserted]} " \
          "metadata_lookup_attempted=#{counts[:metadata_lookup_attempted]} " \
          "metadata_lookup_failed=#{counts[:metadata_lookup_failed]} " \
          "watchables_backfilled=#{counts[:watchables_backfilled]} " \
          "history_state_updates=#{counts[:history_state_updates]} " \
          "history_state_skipped=#{counts[:history_state_skipped]} " \
          "degraded_zero_processed=#{counts[:degraded_zero_processed]}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_history counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :phase_progress, :sync_run

    def incremental_history_rows(adapter:, integration:)
      sync_state = history_sync_state(integration)
      rows = collect_incremental_history_rows(adapter:, integration:, sync_state:)
      return rows unless stale_history_state?(rows:, sync_state:)

      log_info(
        "sync_phase_worker_history_state_reset integration_id=#{integration.id} " \
        "previous_max_seen_history_id=#{sync_state[:max_seen_history_id]} " \
        "observed_max_history_id=#{rows[:observed_max_history_id]}"
      )
      reset_state = { watermark_id: 0, max_seen_history_id: 0, recent_ids: [] }
      refreshed_rows = collect_incremental_history_rows(adapter:, integration:, sync_state: reset_state)
      refreshed_rows[:sync_state] = reset_state
      refreshed_rows
    end

    def collect_incremental_history_rows(adapter:, integration:, sync_state:)
      window_anchor = [ sync_state[:watermark_id], sync_state[:max_seen_history_id] ].max
      lower_bound = [ window_anchor - HISTORY_OVERLAP_ROWS, 0 ].max
      recent_ids = sync_state[:recent_ids].to_set
      seen_history_ids = Set.new
      page_size = integration.tautulli_history_page_size

      start = 0
      fetched_rows = 0
      skipped_rows = 0
      skipped_overlap_rows = 0
      invalid_rows = 0
      max_seen_history_id = sync_state[:max_seen_history_id]
      observed_max_history_id = 0
      rows_to_process = []

      loop do
        page = adapter.fetch_history_page(
          start: start,
          length: page_size,
          order_column: "id",
          order_dir: "desc"
        )
        fetched_count = page.fetch(:raw_rows_count, 0).to_i
        page_rows = page.fetch(:rows)
        break if fetched_count <= 0
        phase_progress&.add_total!(fetched_count * 2)
        phase_progress&.advance!(fetched_count)

        fetched_rows += fetched_count
        skipped_rows += page.fetch(:rows_skipped_invalid, 0).to_i
        invalid_rows += page.fetch(:rows_skipped_invalid, 0).to_i
        page_rows.each do |row|
          history_id = row.fetch(:history_id).to_i
          observed_max_history_id = [ observed_max_history_id, history_id ].max
          max_seen_history_id = [ max_seen_history_id, history_id ].max
          if seen_history_ids.include?(history_id) || history_id <= lower_bound || recent_ids.include?(history_id)
            skipped_rows += 1
            skipped_overlap_rows += 1
            next
          end

          seen_history_ids << history_id
          rows_to_process << row
        end

        break unless page.fetch(:has_more)

        start = page.fetch(:next_start)
      end

      rows_to_process.sort_by! { |row| row.fetch(:history_id).to_i }
      {
        fetched: fetched_rows,
        invalid: invalid_rows,
        skipped: skipped_rows,
        skipped_overlap: skipped_overlap_rows,
        process: rows_to_process,
        sync_state: sync_state,
        max_seen_history_id: max_seen_history_id,
        observed_max_history_id: observed_max_history_id
      }
    end

    def stale_history_state?(rows:, sync_state:)
      prior_max = sync_state[:max_seen_history_id].to_i
      return false if prior_max <= 0
      return false if rows[:fetched].to_i <= 0
      return false if rows[:process].any?
      return false if rows[:observed_max_history_id].to_i <= 0

      window_anchor = [ sync_state[:watermark_id], prior_max ].max
      rows[:observed_max_history_id].to_i < [ window_anchor - HISTORY_OVERLAP_ROWS, 0 ].max
    end

    def upsert_watch_stats!(rows, integration:)
      return empty_upsert_result if rows.empty?

      watched_mode = AppSetting.db_value_for("watched_mode")
      watched_percent_threshold = AppSetting.db_value_for("watched_percent_threshold").to_i
      in_progress_min_offset_ms = AppSetting.db_value_for("in_progress_min_offset_ms").to_i

      watchable_lookup = load_watchables(rows)
      plex_users = PlexUser.where(tautulli_user_id: rows.map { |row| row.fetch(:tautulli_user_id) }.uniq).index_by(&:tautulli_user_id)
      outcome = empty_upsert_result

      rows.each_slice(HISTORY_PROCESS_BATCH_SIZE) do |batch_rows|
        reconciliation = reconcile_missing_watchables!(
          rows: batch_rows,
          watchable_lookup: watchable_lookup,
          integration: integration
        )
        watchable_lookup = reconciliation.fetch(:lookup)

        aggregates, row_outcomes = aggregate_rows(batch_rows, plex_users:, watchable_lookup:)
        row_outcomes[:metadata_lookup_attempted] += reconciliation.fetch(:metadata_lookup_attempted)
        row_outcomes[:metadata_lookup_failed] += reconciliation.fetch(:metadata_lookup_failed)
        row_outcomes[:watchables_backfilled] += reconciliation.fetch(:watchables_backfilled)
        row_outcomes[:watch_stats_upserted] += upsert_aggregates!(
          aggregates:,
          watched_mode:,
          watched_percent_threshold:,
          in_progress_min_offset_ms:
        )
        accumulate_outcome!(target: outcome, source: row_outcomes)
      end

      outcome
    end

    def upsert_aggregates!(aggregates:, watched_mode:, watched_percent_threshold:, in_progress_min_offset_ms:)
      return 0 if aggregates.empty?

      existing = existing_watch_stats_for(aggregates.keys)

      now = Time.current
      payload = aggregates.filter_map do |key, aggregate|
        existing_stat = existing[key]
        merged = merge_aggregate(existing_stat:, aggregate:)
        duration_ms = aggregate[:duration_ms] || aggregate[:watchable_duration_ms]
        watched = watched_for(
          watched_mode: watched_mode,
          watched_percent_threshold: watched_percent_threshold,
          play_count: merged[:play_count],
          max_view_offset_ms: merged[:max_view_offset_ms],
          duration_ms: duration_ms
        )

        {
          plex_user_id: aggregate.fetch(:plex_user_id),
          watchable_type: aggregate.fetch(:watchable_type),
          watchable_id: aggregate.fetch(:watchable_id),
          play_count: merged.fetch(:play_count),
          last_watched_at: merged[:last_watched_at],
          watched: watched,
          in_progress: merged.fetch(:max_view_offset_ms) >= in_progress_min_offset_ms && !watched,
          max_view_offset_ms: merged.fetch(:max_view_offset_ms),
          last_seen_at: merged.fetch(:last_seen_at),
          created_at: now,
          updated_at: now
        }
      end

      return 0 if payload.empty?

      WatchStat.upsert_all(payload, unique_by: %i[plex_user_id watchable_type watchable_id])
      payload.size
    end

    def load_watchables(rows)
      movie_keys = rows.select { |row| row.fetch(:media_type) == "movie" }.map { |row| row.fetch(:plex_rating_key) }.reject(&:blank?).uniq
      episode_keys = rows.select { |row| row.fetch(:media_type) == "episode" }.map { |row| row.fetch(:plex_rating_key) }.reject(&:blank?).uniq

      {
        movies: grouped_watchables_by_key(Movie, movie_keys),
        episodes: grouped_watchables_by_key(Episode, episode_keys)
      }
    end

    def aggregate_rows(rows, plex_users:, watchable_lookup:)
      aggregates = {}
      row_outcomes = empty_upsert_result

      rows.each do |row|
        phase_progress&.advance!(1)
        history_id = row.fetch(:history_id).to_i
        plex_user = plex_users[row.fetch(:tautulli_user_id).to_i]
        if plex_user.blank?
          row_outcomes[:rows_skipped] += 1
          row_outcomes[:rows_skipped_missing_user] += 1
          next
        end

        watchable = watchable_for(row:, lookup: watchable_lookup)
        if watchable == :ambiguous
          row_outcomes[:rows_ambiguous] += 1
          next
        end

        if watchable.blank?
          row_outcomes[:rows_skipped] += 1
          row_outcomes[:rows_skipped_missing_watchable] += 1
          next
        end

        key = [ plex_user.id, watchable.class.name, watchable.id ]
        aggregate = aggregates[key] ||= {
          plex_user_id: plex_user.id,
          watchable_type: watchable.class.name,
          watchable_id: watchable.id,
          play_count: 0,
          last_watched_at: nil,
          max_view_offset_ms: 0,
          last_seen_at: nil,
          duration_ms: nil,
          watchable_duration_ms: watchable.respond_to?(:duration_ms) ? watchable.duration_ms : nil
        }
        row_outcomes[:rows_processed] += 1
        row_outcomes[:processed_history_ids] << history_id
        aggregate[:play_count] += [ row[:play_count].to_i, 1 ].max
        aggregate[:last_watched_at] = [ aggregate[:last_watched_at], row[:viewed_at] ].compact.max
        aggregate[:last_seen_at] = [ aggregate[:last_seen_at], row[:viewed_at] ].compact.max
        aggregate[:max_view_offset_ms] = [ aggregate[:max_view_offset_ms], row[:view_offset_ms].to_i ].max
        aggregate[:duration_ms] = [ aggregate[:duration_ms], row[:duration_ms] ].compact.max
      end

      row_outcomes[:processed_history_ids].uniq!

      [ aggregates, row_outcomes ]
    end

    def existing_watch_stats_for(aggregate_keys)
      return {} if aggregate_keys.empty?

      plex_user_ids = aggregate_keys.map(&:first).uniq
      index = WatchStat.where(plex_user_id: plex_user_ids).index_by do |stat|
        [ stat.plex_user_id, stat.watchable_type, stat.watchable_id ]
      end
      index.slice(*aggregate_keys)
    end

    def merge_aggregate(existing_stat:, aggregate:)
      return aggregate if existing_stat.blank?

      {
        play_count: existing_stat.play_count.to_i + aggregate.fetch(:play_count).to_i,
        last_watched_at: [ existing_stat.last_watched_at, aggregate[:last_watched_at] ].compact.max,
        max_view_offset_ms: [ existing_stat.max_view_offset_ms.to_i, aggregate.fetch(:max_view_offset_ms).to_i ].max,
        last_seen_at: [ existing_stat.last_seen_at, aggregate.fetch(:last_seen_at) ].compact.max
      }
    end

    def watched_for(watched_mode:, watched_percent_threshold:, play_count:, max_view_offset_ms:, duration_ms:)
      return play_count.to_i >= 1 if watched_mode == "play_count"

      return play_count.to_i >= 1 if duration_ms.to_i <= 0

      percent = (max_view_offset_ms.to_f / duration_ms.to_f) * 100.0
      percent >= watched_percent_threshold
    end

    def watchable_for(row:, lookup:)
      watchable = if row.fetch(:media_type) == "movie"
        lookup.fetch(:movies)[row.fetch(:plex_rating_key)]
      else
        lookup.fetch(:episodes)[row.fetch(:plex_rating_key)]
      end

      watchable.equal?(AMBIGUOUS_WATCHABLE) ? :ambiguous : watchable
    end

    def grouped_watchables_by_key(model_class, keys)
      return {} if keys.empty?

      model_class.where(plex_rating_key: keys).group_by(&:plex_rating_key).transform_values do |watchables|
        watchables.one? ? watchables.first : AMBIGUOUS_WATCHABLE
      end
    end

    def reconcile_missing_watchables!(rows:, watchable_lookup:, integration:)
      unresolved_rows = rows.select { |row| watchable_for(row:, lookup: watchable_lookup).blank? }

      unresolved_movies = unresolved_rows.select { |row| row.fetch(:media_type) == "movie" }
      unresolved_episodes = unresolved_rows.select { |row| row.fetch(:media_type) == "episode" }

      return {
        lookup: watchable_lookup,
        metadata_lookup_attempted: 0,
        metadata_lookup_failed: 0,
        watchables_backfilled: 0
      } if unresolved_rows.empty?

      metadata_lookup_attempted = 0
      metadata_lookup_failed = 0
      watchables_backfilled = 0
      resolved_movie_keys = Set.new
      resolved_episode_keys = Set.new

      movie_result = reconcile_movies_by_metadata!(
        rows: unresolved_movies,
        integration: integration
      )
      metadata_lookup_attempted += movie_result.fetch(:metadata_lookup_attempted)
      metadata_lookup_failed += movie_result.fetch(:metadata_lookup_failed)
      watchables_backfilled += movie_result.fetch(:watchables_backfilled)
      resolved_movie_keys.merge(movie_result.fetch(:resolved_keys))

      episode_result = reconcile_episodes_by_series_metadata!(
        rows: unresolved_episodes,
        integration: integration
      )
      metadata_lookup_attempted += episode_result.fetch(:metadata_lookup_attempted)
      metadata_lookup_failed += episode_result.fetch(:metadata_lookup_failed)
      watchables_backfilled += episode_result.fetch(:watchables_backfilled)
      resolved_episode_keys.merge(episode_result.fetch(:resolved_keys))

      unresolved_episode_rows = episode_result.fetch(:unresolved_rows)
      fallback_result = reconcile_episodes_by_episode_metadata!(
        rows: unresolved_episode_rows,
        integration: integration
      )
      metadata_lookup_attempted += fallback_result.fetch(:metadata_lookup_attempted)
      metadata_lookup_failed += fallback_result.fetch(:metadata_lookup_failed)
      watchables_backfilled += fallback_result.fetch(:watchables_backfilled)
      resolved_episode_keys.merge(fallback_result.fetch(:resolved_keys))

      if resolved_movie_keys.any?
        watchable_lookup[:movies].merge!(grouped_watchables_by_key(Movie, resolved_movie_keys.to_a))
      end
      if resolved_episode_keys.any?
        watchable_lookup[:episodes].merge!(grouped_watchables_by_key(Episode, resolved_episode_keys.to_a))
      end

      {
        lookup: watchable_lookup,
        metadata_lookup_attempted: metadata_lookup_attempted,
        metadata_lookup_failed: metadata_lookup_failed,
        watchables_backfilled: watchables_backfilled
      }
    end

    def reconcile_movies_by_metadata!(rows:, integration:)
      unresolved_keys = rows.map { |row| row.fetch(:plex_rating_key).to_s }.reject(&:blank?).uniq
      return empty_reconciliation_result if unresolved_keys.empty?

      metadata_result = fetch_metadata_for_keys(
        integration: integration,
        rating_keys: unresolved_keys,
        namespace: :movie
      )

      watchables_backfilled = 0
      resolved_keys = Set.new

      metadata_result.fetch(:metadata_by_key).each do |rating_key, metadata|
        next if metadata.blank?
        next unless reconcile_movie_watchable!(rating_key:, metadata:)

        watchables_backfilled += 1
        resolved_keys << rating_key
      end

      metadata_result.slice(:metadata_lookup_attempted, :metadata_lookup_failed).merge(
        watchables_backfilled: watchables_backfilled,
        resolved_keys: resolved_keys
      )
    end

    def reconcile_episodes_by_series_metadata!(rows:, integration:)
      unresolved_rows = rows.select do |row|
        row[:plex_grandparent_rating_key].present? &&
          row[:season_number].to_i.positive? &&
          row[:episode_number].to_i.positive?
      end
      return empty_reconciliation_result.merge(unresolved_rows: rows) if unresolved_rows.empty?

      show_keys = unresolved_rows.map { |row| row[:plex_grandparent_rating_key].to_s }.reject(&:blank?).uniq
      metadata_result = fetch_metadata_for_keys(
        integration: integration,
        rating_keys: show_keys,
        namespace: :show
      )
      series_by_show_key = resolve_series_lookup_by_show_key(metadata_by_show_key: metadata_result.fetch(:metadata_by_key))
      episode_lookup = load_episode_lookup_for_series(series_ids: series_by_show_key.values.map(&:id))

      resolved_keys = Set.new
      watchables_backfilled = 0
      still_unresolved_rows = []

      rows.each do |row|
        rating_key = row[:plex_rating_key].to_s
        show_key = row[:plex_grandparent_rating_key].to_s
        season_number = row[:season_number].to_i
        episode_number = row[:episode_number].to_i
        if rating_key.blank? || show_key.blank? || season_number <= 0 || episode_number <= 0
          still_unresolved_rows << row
          next
        end

        series = series_by_show_key[show_key]
        if series.blank?
          still_unresolved_rows << row
          next
        end

        episode = episode_from_position(
          series_id: series.id,
          season_number: season_number,
          episode_number: episode_number,
          lookup: episode_lookup
        )
        if episode.blank? || episode == :ambiguous
          still_unresolved_rows << row
          next
        end
        if episode.plex_rating_key.present? && episode.plex_rating_key != rating_key
          still_unresolved_rows << row
          next
        end

        persisted = persist_watchable_metadata!(
          watchable: episode,
          rating_key: rating_key,
          metadata: {
            plex_guid: row[:plex_guid],
            duration_ms: row[:duration_ms]
          }
        )
        if persisted
          watchables_backfilled += 1
          resolved_keys << rating_key
        end
      end

      metadata_result.slice(:metadata_lookup_attempted, :metadata_lookup_failed).merge(
        watchables_backfilled: watchables_backfilled,
        resolved_keys: resolved_keys,
        unresolved_rows: still_unresolved_rows
      )
    end

    def reconcile_episodes_by_episode_metadata!(rows:, integration:)
      unresolved_keys = rows.map { |row| row.fetch(:plex_rating_key).to_s }.reject(&:blank?).uniq
      return empty_reconciliation_result if unresolved_keys.empty?

      metadata_result = fetch_metadata_for_keys(
        integration: integration,
        rating_keys: unresolved_keys,
        namespace: :episode
      )

      watchables_backfilled = 0
      resolved_keys = Set.new
      metadata_result.fetch(:metadata_by_key).each do |rating_key, metadata|
        next if metadata.blank?
        next unless reconcile_episode_watchable!(rating_key:, metadata:)

        watchables_backfilled += 1
        resolved_keys << rating_key
      end

      metadata_result.slice(:metadata_lookup_attempted, :metadata_lookup_failed).merge(
        watchables_backfilled: watchables_backfilled,
        resolved_keys: resolved_keys
      )
    end

    def resolve_series_lookup_by_show_key(metadata_by_show_key:)
      metadata_rows = metadata_by_show_key.filter_map do |show_key, metadata|
        external_ids = metadata.fetch(:external_ids, {})
        next if external_ids.blank?

        [ show_key, external_ids ]
      end
      return {} if metadata_rows.empty?

      tvdb_ids = metadata_rows.filter_map { |(_, external_ids)| external_ids[:tvdb_id] }.uniq
      imdb_ids = metadata_rows.filter_map { |(_, external_ids)| external_ids[:imdb_id] }.uniq
      tmdb_ids = metadata_rows.filter_map { |(_, external_ids)| external_ids[:tmdb_id] }.uniq

      candidates = Series.none
      candidates = candidates.or(Series.where(tvdb_id: tvdb_ids)) if tvdb_ids.any?
      candidates = candidates.or(Series.where(imdb_id: imdb_ids)) if imdb_ids.any?
      candidates = candidates.or(Series.where(tmdb_id: tmdb_ids)) if tmdb_ids.any?
      series_rows = candidates.to_a

      metadata_rows.each_with_object({}) do |(show_key, external_ids), result|
        matches = []
        matches.concat(series_rows.select { |series| series.tvdb_id.present? && series.tvdb_id == external_ids[:tvdb_id] }) if external_ids[:tvdb_id].present?
        matches.concat(series_rows.select { |series| series.imdb_id.present? && series.imdb_id == external_ids[:imdb_id] }) if external_ids[:imdb_id].present?
        matches.concat(series_rows.select { |series| series.tmdb_id.present? && series.tmdb_id == external_ids[:tmdb_id] }) if external_ids[:tmdb_id].present?
        matches.uniq!(&:id)
        result[show_key] = matches.first if matches.one?
      end
    end

    def load_episode_lookup_for_series(series_ids:)
      return { seasons: {}, episodes: {} } if series_ids.empty?

      seasons = Season.where(series_id: series_ids).select(:id, :series_id, :season_number).to_a
      seasons_by_key = seasons.index_by { |season| [ season.series_id, season.season_number ] }
      season_ids = seasons.map(&:id)
      return { seasons: seasons_by_key, episodes: {} } if season_ids.empty?

      episodes = Episode.where(season_id: season_ids).to_a
      episodes_by_key = episodes.group_by { |episode| [ episode.season_id, episode.episode_number ] }.transform_values do |group|
        group.one? ? group.first : :ambiguous
      end
      { seasons: seasons_by_key, episodes: episodes_by_key }
    end

    def episode_from_position(series_id:, season_number:, episode_number:, lookup:)
      season = lookup.fetch(:seasons)[[ series_id, season_number ]]
      return nil if season.blank?

      lookup.fetch(:episodes)[[ season.id, episode_number ]]
    end

    def fetch_metadata_for_keys(integration:, rating_keys:, namespace:)
      metadata_cache = metadata_cache_for(namespace)
      metadata_miss_keys = metadata_miss_keys_for(namespace)

      requested_keys = rating_keys.map(&:to_s).reject(&:blank?).uniq
      metadata_by_key = requested_keys.filter_map do |rating_key|
        [ rating_key, metadata_cache[rating_key] ] if metadata_cache.key?(rating_key)
      end.to_h
      keys_to_fetch = requested_keys - metadata_by_key.keys - metadata_miss_keys.to_a

      return {
        metadata_by_key: metadata_by_key,
        metadata_lookup_attempted: 0,
        metadata_lookup_failed: 0
      } if keys_to_fetch.empty?

      phase_progress&.add_total!(keys_to_fetch.size)
      work_queue = Queue.new
      result_queue = Queue.new
      keys_to_fetch.each { |rating_key| work_queue << rating_key }

      worker_count = [ integration.tautulli_metadata_workers_resolved, keys_to_fetch.size ].min
      worker_count = 1 if worker_count <= 0
      worker_count.times { work_queue << nil }

      threads = Array.new(worker_count) do
        Thread.new do
          thread_adapter = Integrations::TautulliAdapter.new(integration: integration)
          loop do
            rating_key = work_queue.pop
            break if rating_key.nil?

            metadata = fetch_metadata_for_rating_key(adapter: thread_adapter, rating_key: rating_key, namespace: namespace)
            result_queue << [ rating_key, metadata ]
          rescue StandardError => error
            log_info(
              "sync_phase_worker_metadata_lookup_failed phase=tautulli_history " \
              "namespace=#{namespace} rating_key=#{rating_key} error=#{error.class.name}"
            )
            result_queue << [ rating_key, nil ]
          end
        end
      end

      metadata_lookup_failed = 0
      keys_to_fetch.size.times do
        rating_key, metadata = result_queue.pop
        phase_progress&.advance!(1)
        if metadata.blank?
          metadata_lookup_failed += 1
          metadata_miss_keys << rating_key
          next
        end

        metadata_cache[rating_key] = metadata
        metadata_by_key[rating_key] = metadata
      end

      {
        metadata_by_key: metadata_by_key,
        metadata_lookup_attempted: keys_to_fetch.size,
        metadata_lookup_failed: metadata_lookup_failed
      }
    ensure
      threads&.each(&:join)
    end

    def fetch_metadata_for_rating_key(adapter:, rating_key:, namespace:)
      adapter.fetch_metadata(rating_key:)
    rescue Integrations::Error => error
      log_info(
        "sync_phase_worker_metadata_lookup_failed phase=tautulli_history " \
        "namespace=#{namespace} rating_key=#{rating_key} error=#{error.class.name}"
      )
      nil
    end

    def reconcile_movie_watchable!(rating_key:, metadata:)
      watchable = uniquely_matched_watchable(
        relation: Movie.all,
        external_ids: metadata.fetch(:external_ids, {}),
        type: :movie
      )
      return false if watchable.blank?
      return false if watchable.plex_rating_key.present? && watchable.plex_rating_key != rating_key

      persist_watchable_metadata!(watchable:, rating_key:, metadata:)
    end

    def reconcile_episode_watchable!(rating_key:, metadata:)
      watchable = uniquely_matched_watchable(
        relation: Episode.all,
        external_ids: metadata.fetch(:external_ids, {}),
        type: :episode
      )
      return false if watchable.blank?
      return false if watchable.plex_rating_key.present? && watchable.plex_rating_key != rating_key

      persist_watchable_metadata!(watchable:, rating_key:, metadata:)
    end

    def uniquely_matched_watchable(relation:, external_ids:, type:)
      matches = []
      if type == :movie
        matches.concat(relation.where(tmdb_id: external_ids[:tmdb_id])) if external_ids[:tmdb_id].present?
        matches.concat(relation.where(imdb_id: external_ids[:imdb_id])) if external_ids[:imdb_id].present?
      else
        matches.concat(relation.where(tvdb_id: external_ids[:tvdb_id])) if external_ids[:tvdb_id].present?
        matches.concat(relation.where(imdb_id: external_ids[:imdb_id])) if external_ids[:imdb_id].present?
        matches.concat(relation.where(tmdb_id: external_ids[:tmdb_id])) if external_ids[:tmdb_id].present?
      end
      matches.uniq!(&:id)
      return nil unless matches.one?

      matches.first
    end

    def persist_watchable_metadata!(watchable:, rating_key:, metadata:)
      attrs = {}
      attrs[:plex_rating_key] = rating_key if watchable.plex_rating_key.blank?
      attrs[:plex_guid] = metadata[:plex_guid] if watchable.plex_guid.blank? && metadata[:plex_guid].present?
      attrs[:duration_ms] = metadata[:duration_ms] if watchable.duration_ms.blank? && metadata[:duration_ms].present?
      return false if attrs.empty?

      watchable.update!(attrs)
      true
    end

    def empty_upsert_result
      {
        rows_processed: 0,
        rows_skipped: 0,
        rows_skipped_missing_user: 0,
        rows_skipped_missing_watchable: 0,
        rows_ambiguous: 0,
        watch_stats_upserted: 0,
        metadata_lookup_attempted: 0,
        metadata_lookup_failed: 0,
        watchables_backfilled: 0,
        processed_history_ids: []
      }
    end

    def empty_reconciliation_result
      {
        metadata_lookup_attempted: 0,
        metadata_lookup_failed: 0,
        watchables_backfilled: 0,
        resolved_keys: Set.new
      }
    end

    def accumulate_outcome!(target:, source:)
      target[:rows_processed] += source[:rows_processed].to_i
      target[:rows_skipped] += source[:rows_skipped].to_i
      target[:rows_skipped_missing_user] += source[:rows_skipped_missing_user].to_i
      target[:rows_skipped_missing_watchable] += source[:rows_skipped_missing_watchable].to_i
      target[:rows_ambiguous] += source[:rows_ambiguous].to_i
      target[:watch_stats_upserted] += source[:watch_stats_upserted].to_i
      target[:metadata_lookup_attempted] += source[:metadata_lookup_attempted].to_i
      target[:metadata_lookup_failed] += source[:metadata_lookup_failed].to_i
      target[:watchables_backfilled] += source[:watchables_backfilled].to_i
      target[:processed_history_ids].concat(Array(source[:processed_history_ids]))
      target[:processed_history_ids].uniq!
    end

    def reset_metadata_caches!
      @metadata_cache_by_namespace = {}
      @metadata_miss_keys_by_namespace = {}
    end

    def metadata_cache_for(namespace)
      @metadata_cache_by_namespace ||= {}
      @metadata_cache_by_namespace[namespace.to_s] ||= {}
    end

    def metadata_miss_keys_for(namespace)
      @metadata_miss_keys_by_namespace ||= {}
      @metadata_miss_keys_by_namespace[namespace.to_s] ||= Set.new
    end

    def history_sync_state(integration)
      raw = integration.settings_json["history_sync_state"]
      watermark_id = raw&.dig("watermark_id").to_i
      max_seen_history_id = [ raw&.dig("max_seen_history_id").to_i, watermark_id ].max
      {
        watermark_id: watermark_id,
        max_seen_history_id: max_seen_history_id,
        recent_ids: Array(raw&.dig("recent_ids")).map(&:to_i)
      }
    end

    def next_history_state(sync_state:, max_seen_history_id:, processed_history_ids:)
      processed_max = processed_history_ids.max.to_i
      watermark_id = [ sync_state[:watermark_id], processed_max ].max
      max_seen_history_id_value = if processed_history_ids.any?
        [ sync_state[:max_seen_history_id], max_seen_history_id.to_i, watermark_id ].max
      else
        [ sync_state[:max_seen_history_id], watermark_id ].max
      end
      {
        watermark_id: watermark_id,
        max_seen_history_id: max_seen_history_id_value,
        recent_ids: (sync_state[:recent_ids] + processed_history_ids).uniq.last(RECENT_HISTORY_MEMORY)
      }
    end

    def persist_history_state!(integration:, state:)
      return false if history_sync_state(integration) == state

      integration.update!(settings_json: integration.settings_json.merge("history_sync_state" => state))
      true
    end

    def log_info(message)
      Rails.logger.info(
        [
          message,
          "sync_run_id=#{sync_run.id}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end
  end
end
