module Sync
  class RunProgressBroadcaster
    STREAM = "sync_runs".freeze
    TARGET = "sync-runs-snapshot".freeze

    class << self
      def broadcast(sync_run: nil, correlation_id: nil)
        Turbo::StreamsChannel.broadcast_update_to(
          STREAM,
          target: TARGET,
          html: ApplicationController.render(
            partial: "runs/sync_runs_snapshot",
            locals: snapshot_locals
          )
        )
        ActionCable.server.broadcast(
          STREAM,
          sync_event_payload(sync_run:, correlation_id:)
        )
      rescue StandardError => error
        Rails.logger.warn("sync_run_progress_broadcast_failed class=#{error.class} message=#{error.message}")
      end

      private

      def snapshot_locals
        sync_enabled = ActiveModel::Type::Boolean.new.cast(AppSetting.db_value_for("sync_enabled"))
        sync_interval_minutes = [ AppSetting.db_value_for("sync_interval_minutes").to_i, 1 ].max
        schedule_window = Sync::ScheduleWindow.new(sync_enabled:, sync_interval_minutes:)

        {
          running_sync_run: SyncRun.where(status: "running").recent_first.first,
          recent_sync_runs: SyncRun.recent_first.limit(20),
          sync_enabled: sync_enabled,
          sync_interval_minutes: sync_interval_minutes,
          last_successful_sync: schedule_window.last_successful_sync,
          next_scheduled_sync_at: schedule_window.next_scheduled_sync_at
        }
      end

      def sync_event_payload(sync_run:, correlation_id:)
        run = sync_run || SyncRun.recent_first.first
        return { event: "sync_run.updated", correlation_id: correlation_id.presence || SecureRandom.uuid } if run.blank?

        {
          event: "sync_run.updated",
          id: run.id,
          status: run.status,
          trigger: run.trigger,
          phase: run.phase,
          phase_label: Sync::RunSync.phase_label_for(run.phase.presence || "starting"),
          progress: run.progress_snapshot,
          queued_next: run.queued_next,
          error_code: run.error_code,
          correlation_id: correlation_id.presence || SecureRandom.uuid
        }
      end
    end
  end
end
