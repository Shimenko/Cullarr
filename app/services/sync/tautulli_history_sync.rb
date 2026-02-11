require "set"

module Sync
  class TautulliHistorySync
    AMBIGUOUS_WATCHABLE = Object.new.freeze

    HISTORY_OVERLAP_ROWS = 100
    RECENT_HISTORY_MEMORY = 1000
    METADATA_RECONCILIATION_LIMIT = 250

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
        watch_stats_upserted: 0
      }

      log_info("sync_phase_worker_started phase=tautulli_history")
      Integration.tautulli.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        adapter = Integrations::TautulliAdapter.new(integration:)
        page_size = integration.tautulli_history_page_size
        rows = incremental_history_rows(adapter:, integration:)
        counts[:rows_fetched] += rows[:fetched]
        counts[:rows_skipped_overlap] += rows[:skipped_overlap]
        upsert_result = upsert_watch_stats!(rows[:process], adapter:)
        counts[:rows_processed] += upsert_result[:rows_processed]
        counts[:rows_invalid] += rows[:invalid]
        counts[:rows_skipped_missing_user] += upsert_result[:rows_skipped_missing_user]
        counts[:rows_skipped_missing_watchable] += upsert_result[:rows_skipped_missing_watchable]
        counts[:rows_skipped] += rows[:invalid] + rows[:skipped_overlap] + upsert_result[:rows_skipped]
        counts[:rows_ambiguous] += upsert_result[:rows_ambiguous]
        counts[:watch_stats_upserted] += upsert_result[:watch_stats_upserted]
        phase_progress&.advance!(rows[:process].size + rows[:skipped])

        persist_history_state!(
          integration: integration,
          state: next_history_state(
            sync_state: rows[:sync_state],
            max_seen_history_id: rows[:max_seen_history_id],
            processed_history_ids: upsert_result[:processed_history_ids]
          )
        )

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_history integration_id=#{integration.id} " \
          "page_size=#{page_size} " \
          "rows_fetched=#{counts[:rows_fetched]} rows_processed=#{counts[:rows_processed]} " \
          "rows_invalid=#{counts[:rows_invalid]} " \
          "rows_skipped=#{counts[:rows_skipped]} rows_skipped_overlap=#{counts[:rows_skipped_overlap]} " \
          "rows_skipped_missing_user=#{counts[:rows_skipped_missing_user]} " \
          "rows_skipped_missing_watchable=#{counts[:rows_skipped_missing_watchable]} " \
          "rows_ambiguous=#{counts[:rows_ambiguous]} " \
          "watch_stats_upserted=#{counts[:watch_stats_upserted]}"
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

    def upsert_watch_stats!(rows, adapter:)
      return empty_upsert_result if rows.empty?

      watched_mode = AppSetting.db_value_for("watched_mode")
      watched_percent_threshold = AppSetting.db_value_for("watched_percent_threshold").to_i
      in_progress_min_offset_ms = AppSetting.db_value_for("in_progress_min_offset_ms").to_i

      watchable_lookup = load_watchables(rows)
      watchable_lookup = reconcile_missing_watchables!(rows:, watchable_lookup:, adapter:)
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

    def reconcile_missing_watchables!(rows:, watchable_lookup:, adapter:)
      unresolved_rows = rows.select { |row| watchable_for(row:, lookup: watchable_lookup).blank? }
      unresolved_keys = unresolved_rows
        .map { |row| [ row.fetch(:media_type), row.fetch(:plex_rating_key).to_s ] }
        .reject { |(_, rating_key)| rating_key.blank? }
        .uniq
        .first(METADATA_RECONCILIATION_LIMIT)
      return watchable_lookup if unresolved_keys.empty?

      metadata_by_key = {}
      resolved_movie_keys = Set.new
      resolved_episode_keys = Set.new

      unresolved_keys.each do |media_type, rating_key|
        metadata = metadata_by_key[rating_key] ||= fetch_metadata_for_rating_key(adapter:, rating_key:)
        next if metadata.blank?

        resolved = if media_type == "movie"
          reconcile_movie_watchable!(rating_key:, metadata:)
        else
          reconcile_episode_watchable!(rating_key:, metadata:)
        end
        next unless resolved

        (media_type == "movie" ? resolved_movie_keys : resolved_episode_keys) << rating_key
      end

      if resolved_movie_keys.any?
        watchable_lookup[:movies].merge!(grouped_watchables_by_key(Movie, resolved_movie_keys.to_a))
      end
      if resolved_episode_keys.any?
        watchable_lookup[:episodes].merge!(grouped_watchables_by_key(Episode, resolved_episode_keys.to_a))
      end

      watchable_lookup
    end

    def fetch_metadata_for_rating_key(adapter:, rating_key:)
      adapter.fetch_metadata(rating_key:)
    rescue Integrations::Error => error
      log_info(
        "sync_phase_worker_metadata_lookup_failed phase=tautulli_history " \
        "rating_key=#{rating_key} error=#{error.class.name}"
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
        processed_history_ids: []
      }
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
      {
        watermark_id: watermark_id,
        max_seen_history_id: [ sync_state[:max_seen_history_id], max_seen_history_id.to_i, watermark_id ].max,
        recent_ids: (sync_state[:recent_ids] + processed_history_ids).uniq.last(RECENT_HISTORY_MEMORY)
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
