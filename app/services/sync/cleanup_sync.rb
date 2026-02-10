module Sync
  class CleanupSync
    def initialize(sync_run:, correlation_id:, phase_progress: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_progress = phase_progress
    end

    def call
      phase_progress&.add_total!(1)
      stale_sync_runs = SyncRun.where(status: "running").where("updated_at < ?", 12.hours.ago).count
      counts = { stale_running_runs_observed: stale_sync_runs }
      phase_progress&.advance!(1)
      log_info("sync_phase_worker_completed phase=cleanup counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :phase_progress, :sync_run

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
