require "set"

module Sync
  class TautulliHistorySync
    AMBIGUOUS_WATCHABLE = Object.new.freeze

    HISTORY_PAGE_SIZE = 200
    HISTORY_OVERLAP_ROWS = 100
    RECENT_HISTORY_MEMORY = 1000

    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      counts = {
        integrations: 0,
        rows_fetched: 0,
        rows_processed: 0,
        rows_skipped: 0,
        rows_ambiguous: 0,
        watch_stats_upserted: 0
      }

      log_info("sync_phase_worker_started phase=tautulli_history")
      Integration.tautulli.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::TautulliAdapter.new(integration:)
        rows, state = incremental_history_rows(adapter:, integration:)
        counts[:rows_fetched] += rows[:fetched]
        upsert_result = upsert_watch_stats!(rows[:process])
        counts[:rows_processed] += upsert_result[:rows_processed]
        counts[:rows_skipped] += rows[:skipped] + upsert_result[:rows_skipped]
        counts[:rows_ambiguous] += upsert_result[:rows_ambiguous]
        counts[:watch_stats_upserted] += upsert_result[:watch_stats_upserted]

        persist_history_state!(integration:, state:)

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_history integration_id=#{integration.id} " \
          "rows_fetched=#{counts[:rows_fetched]} rows_processed=#{counts[:rows_processed]} " \
          "rows_skipped=#{counts[:rows_skipped]} rows_ambiguous=#{counts[:rows_ambiguous]} " \
          "watch_stats_upserted=#{counts[:watch_stats_upserted]}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_history counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

    def incremental_history_rows(adapter:, integration:)
      sync_state = history_sync_state(integration)
      lower_bound = [ sync_state[:watermark_id] - HISTORY_OVERLAP_ROWS, 0 ].max
      recent_ids = sync_state[:recent_ids].to_set

      start = 0
      fetched_rows = 0
      skipped_rows = 0
      rows_to_process = []

      loop do
        page = adapter.fetch_history_page(
          start: start,
          length: HISTORY_PAGE_SIZE,
          order_column: "id",
          order_dir: "desc"
        )
        page_rows = page.fetch(:rows)
        break if page_rows.empty?

        fetched_rows += page_rows.size
        page_rows.each do |row|
          history_id = row.fetch(:history_id).to_i
          if history_id <= lower_bound || recent_ids.include?(history_id)
            skipped_rows += 1
            next
          end

          rows_to_process << row
        end

        break if page_rows.all? { |row| row.fetch(:history_id).to_i <= lower_bound }
        break unless page.fetch(:has_more)

        start = page.fetch(:next_start)
      end

      rows_to_process.sort_by! { |row| row.fetch(:history_id).to_i }
      processed_ids = rows_to_process.map { |row| row.fetch(:history_id).to_i }
      {
        fetched: fetched_rows,
        skipped: skipped_rows,
        process: rows_to_process
      }.yield_self do |rows|
        [
          rows,
          {
            watermark_id: [ sync_state[:watermark_id], processed_ids.max.to_i ].max,
            recent_ids: (sync_state[:recent_ids] + processed_ids).uniq.last(RECENT_HISTORY_MEMORY)
          }
        ]
      end
    end

    def upsert_watch_stats!(rows)
      return empty_upsert_result if rows.empty?

      watched_mode = AppSetting.db_value_for("watched_mode")
      watched_percent_threshold = AppSetting.db_value_for("watched_percent_threshold").to_i
      in_progress_min_offset_ms = AppSetting.db_value_for("in_progress_min_offset_ms").to_i

      watchable_lookup = load_watchables(rows)
      plex_users = PlexUser.where(tautulli_user_id: rows.map { |row| row.fetch(:tautulli_user_id) }.uniq).index_by(&:tautulli_user_id)

      aggregates, row_outcomes = aggregate_rows(rows, plex_users:, watchable_lookup:)
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

      return row_outcomes.merge(watch_stats_upserted: 0) if payload.empty?

      WatchStat.upsert_all(payload, unique_by: %i[plex_user_id watchable_type watchable_id])
      row_outcomes.merge(watch_stats_upserted: payload.size)
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
        plex_user = plex_users[row.fetch(:tautulli_user_id).to_i]
        if plex_user.blank?
          row_outcomes[:rows_skipped] += 1
          next
        end

        watchable = watchable_for(row:, lookup: watchable_lookup)
        if watchable == :ambiguous
          row_outcomes[:rows_ambiguous] += 1
          next
        end

        if watchable.blank?
          row_outcomes[:rows_skipped] += 1
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
        aggregate[:play_count] += [ row[:play_count].to_i, 1 ].max
        aggregate[:last_watched_at] = [ aggregate[:last_watched_at], row[:viewed_at] ].compact.max
        aggregate[:last_seen_at] = [ aggregate[:last_seen_at], row[:viewed_at] ].compact.max
        aggregate[:max_view_offset_ms] = [ aggregate[:max_view_offset_ms], row[:view_offset_ms].to_i ].max
        aggregate[:duration_ms] = [ aggregate[:duration_ms], row[:duration_ms] ].compact.max
      end

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

    def empty_upsert_result
      { rows_processed: 0, rows_skipped: 0, rows_ambiguous: 0, watch_stats_upserted: 0 }
    end

    def history_sync_state(integration)
      raw = integration.settings_json["history_sync_state"]
      {
        watermark_id: raw&.dig("watermark_id").to_i,
        recent_ids: Array(raw&.dig("recent_ids")).map(&:to_i)
      }
    end

    def persist_history_state!(integration:, state:)
      integration.update!(settings_json: integration.settings_json.merge("history_sync_state" => state))
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
