module Sync
  class TautulliUsersSync
    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      counts = {
        integrations: 0,
        users_fetched: 0,
        users_upserted: 0
      }

      log_info("sync_phase_worker_started phase=tautulli_users")
      Integration.tautulli.find_each do |integration|
        Integrations::HealthCheck.new(integration, raise_on_unsupported: true).call
        counts[:integrations] += 1

        users = Integrations::TautulliAdapter.new(integration:).fetch_users
        counts[:users_fetched] += users.size
        counts[:users_upserted] += upsert_users!(users)

        log_info(
          "sync_phase_worker_integration_complete phase=tautulli_users integration_id=#{integration.id} " \
          "users_fetched=#{counts[:users_fetched]} users_upserted=#{counts[:users_upserted]}"
        )
      end

      log_info("sync_phase_worker_completed phase=tautulli_users counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

    def upsert_users!(users)
      return 0 if users.empty?

      now = Time.current
      payload = users.map do |user|
        {
          tautulli_user_id: user.fetch(:tautulli_user_id),
          friendly_name: user.fetch(:friendly_name),
          is_hidden: user.fetch(:is_hidden),
          created_at: now,
          updated_at: now
        }
      end
      PlexUser.upsert_all(payload, unique_by: :tautulli_user_id)
      payload.size
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
