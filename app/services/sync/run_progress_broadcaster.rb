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
        last_successful_sync = SyncRun.where(status: "success").where.not(finished_at: nil).order(finished_at: :desc).first

        {
          running_sync_run: SyncRun.where(status: "running").recent_first.first,
          recent_sync_runs: SyncRun.recent_first.limit(20),
          sync_enabled: sync_enabled,
          sync_interval_minutes: sync_interval_minutes,
          last_successful_sync: last_successful_sync,
          next_scheduled_sync_at: sync_enabled ? next_scheduled_sync_at(last_successful_sync:, sync_interval_minutes:) : nil
        }
      end

      def next_scheduled_sync_at(last_successful_sync:, sync_interval_minutes:)
        return Time.current if last_successful_sync.blank?

        last_successful_sync.finished_at + sync_interval_minutes.minutes
      end

      def sync_event_payload(sync_run:, correlation_id:)
        run = sync_run || SyncRun.recent_first.first
        return { event: "sync_run.updated", correlation_id: correlation_id.presence || SecureRandom.uuid } if run.blank?

        {
          event: "sync_run.updated",
          id: run.id,
          status: run.status,
          phase: run.phase,
          queued_next: run.queued_next,
          correlation_id: correlation_id.presence || SecureRandom.uuid
        }
      end
    end
  end
end
