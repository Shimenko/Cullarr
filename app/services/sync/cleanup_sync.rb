module Sync
  class CleanupSync
    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      stale_sync_runs = SyncRun.where(status: "running").where("updated_at < ?", 12.hours.ago).count
      counts = { stale_running_runs_observed: stale_sync_runs }
      log_info("sync_phase_worker_completed phase=cleanup counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

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
