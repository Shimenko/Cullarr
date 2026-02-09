module Sync
  class CleanupSync
    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      stale_sync_runs = SyncRun.where(status: "running").where("updated_at < ?", 12.hours.ago).count
      { stale_running_runs_observed: stale_sync_runs }
    end

    private

    attr_reader :correlation_id, :sync_run
  end
end
