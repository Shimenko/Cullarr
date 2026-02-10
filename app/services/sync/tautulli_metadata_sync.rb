module Sync
  class TautulliMetadataSync
    WATCHABLE_BATCH_LIMIT = 500

    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
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

        adapter = Integrations::TautulliAdapter.new(integration:)
        watchables_needing_metadata.each do |watchable|
          counts[:metadata_requested] += 1

          begin
            metadata = adapter.fetch_metadata(rating_key: watchable.plex_rating_key)
          rescue Integrations::ContractMismatchError
            counts[:metadata_skipped] += 1
            next
          end

          counts[:watchables_updated] += 1 if apply_metadata!(watchable, metadata)
        end

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_metadata integration_id=#{integration.id} " \
          "metadata_requested=#{counts[:metadata_requested]} watchables_updated=#{counts[:watchables_updated]} " \
          "metadata_skipped=#{counts[:metadata_skipped]}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_metadata counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

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
