module Sync
  class RunProgressBroadcaster
    STREAM = "sync_runs".freeze
    TARGET = "sync-runs-snapshot".freeze

    class << self
      def broadcast
        Turbo::StreamsChannel.broadcast_update_to(
          STREAM,
          target: TARGET,
          html: ApplicationController.render(
            partial: "runs/sync_runs_snapshot",
            locals: snapshot_locals
          )
        )
      rescue StandardError => error
        Rails.logger.warn("sync_run_progress_broadcast_failed class=#{error.class} message=#{error.message}")
      end

      private

      def snapshot_locals
        {
          running_sync_run: SyncRun.where(status: "running").recent_first.first,
          recent_sync_runs: SyncRun.recent_first.limit(20)
        }
      end
    end
  end
end
