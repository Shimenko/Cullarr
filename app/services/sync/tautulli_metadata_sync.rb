module Sync
  class TautulliMetadataSync
    WATCHABLE_BATCH_LIMIT = 500

    def initialize(sync_run:, correlation_id:, phase_progress: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_progress = phase_progress
    end

    def call
      counts = {
        integrations: 0,
        metadata_requested: 0,
        watchables_updated: 0,
        metadata_skipped: 0
      }

      log_info("sync_phase_worker_started phase=tautulli_metadata")
      Integration.tautulli.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        watchables = watchables_needing_metadata
        worker_count = integration.tautulli_metadata_workers_resolved
        phase_progress&.add_total!(watchables.size)
        counts[:metadata_requested] += watchables.size

        process_watchables_concurrently(integration:, watchables:, worker_count:) do |result|
          counts[:metadata_skipped] += 1 if result.fetch(:skipped)
          counts[:watchables_updated] += 1 if result.fetch(:updated)
          phase_progress&.advance!(1)
        end

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_metadata integration_id=#{integration.id} " \
          "metadata_workers=#{worker_count} " \
          "metadata_requested=#{counts[:metadata_requested]} watchables_updated=#{counts[:watchables_updated]} " \
          "metadata_skipped=#{counts[:metadata_skipped]}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_metadata counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :phase_progress, :sync_run

    def process_watchables_concurrently(integration:, watchables:, worker_count:)
      return if watchables.empty?

      work_queue = Queue.new
      result_queue = Queue.new
      watchables.each { |watchable| work_queue << watchable }

      worker_count = [ worker_count, watchables.size ].min
      worker_count = 1 if worker_count <= 0
      worker_count.times { work_queue << nil }

      threads = Array.new(worker_count) do
        Thread.new do
          thread_adapter = begin
            Integrations::TautulliAdapter.new(integration:)
          rescue StandardError => error
            log_info(
              "sync_phase_worker_adapter_init_failed phase=tautulli_metadata " \
              "integration_id=#{integration.id} error=#{error.class.name}"
            )
            nil
          end

          loop do
            watchable = work_queue.pop
            break if watchable.nil?

            if thread_adapter.nil?
              result_queue << { skipped: true }
              next
            end

            begin
              metadata = thread_adapter.fetch_metadata(rating_key: watchable.plex_rating_key)
              result_queue << { watchable: watchable, metadata: metadata }
            rescue Integrations::ContractMismatchError
              result_queue << { skipped: true }
            rescue StandardError => error
              log_info(
                "sync_phase_worker_metadata_lookup_failed phase=tautulli_metadata " \
                "integration_id=#{integration.id} watchable_type=#{watchable.class.name} " \
                "watchable_id=#{watchable.id} error=#{error.class.name}"
              )
              result_queue << { skipped: true }
            end
          end
        end
      end

      watchables.size.times do
        result = result_queue.pop
        if result[:watchable].present?
          updated = apply_metadata!(result.fetch(:watchable), result.fetch(:metadata))
          yield({ skipped: false, updated: updated })
        else
          yield({ skipped: true, updated: false })
        end
      end
    ensure
      threads&.each(&:join)
    end

    def watchables_needing_metadata
      movie_scope = Movie.where.not(plex_rating_key: [ nil, "" ])
                         .where("duration_ms IS NULL OR plex_guid IS NULL")
      episode_scope = Episode.where.not(plex_rating_key: [ nil, "" ])
                             .where("duration_ms IS NULL OR plex_guid IS NULL")

      ids = movie_scope.limit(WATCHABLE_BATCH_LIMIT).pluck(:id).map { |id| [ "Movie", id ] }
      ids += episode_scope.limit(WATCHABLE_BATCH_LIMIT).pluck(:id).map { |id| [ "Episode", id ] }

      movie_ids = ids.filter_map { |type, id| type == "Movie" ? id : nil }
      episode_ids = ids.filter_map { |type, id| type == "Episode" ? id : nil }

      movies = Movie.where(id: movie_ids)
      episodes = Episode.where(id: episode_ids)
      movies.to_a + episodes.to_a
    end

    def apply_metadata!(watchable, metadata)
      external_ids = metadata[:external_ids] || {}
      attrs = {
        duration_ms: watchable.duration_ms || metadata[:duration_ms],
        plex_guid: watchable.plex_guid || metadata[:plex_guid]
      }

      if watchable.is_a?(Movie)
        attrs[:imdb_id] = watchable.imdb_id || external_ids[:imdb_id]
        attrs[:tmdb_id] = watchable.tmdb_id || external_ids[:tmdb_id]
      else
        attrs[:imdb_id] = watchable.imdb_id || external_ids[:imdb_id]
        attrs[:tmdb_id] = watchable.tmdb_id || external_ids[:tmdb_id]
        attrs[:tvdb_id] = watchable.tvdb_id || external_ids[:tvdb_id]
      end

      merged_metadata = watchable.metadata_json.merge("metadata_synced_at" => Time.current.iso8601)
      attrs[:metadata_json] = merged_metadata

      watchable.update!(attrs)
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
