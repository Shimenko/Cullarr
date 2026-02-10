module Deletion
  class RunStatusBroadcaster
    STREAM = "deletion_runs".freeze
    RUNS_TARGET = "deletion-runs-snapshot".freeze
    RUN_TARGET = "deletion-run-snapshot".freeze

    class << self
      def broadcast_run(deletion_run:, correlation_id:)
        summary = DeletionRun.action_summary_by_run_id([ deletion_run.id ]).fetch(
          deletion_run.id,
          DeletionRun.default_action_summary
        )

        ActionCable.server.broadcast(
          STREAM,
          {
            event: "deletion_run.updated",
            id: deletion_run.id,
            status: deletion_run.status,
            summary: summary,
            correlation_id: correlation_id
          }
        )
        broadcast_runs_snapshot
        broadcast_run_snapshot(deletion_run_id: deletion_run.id)
      rescue StandardError => error
        Rails.logger.warn("deletion_run_progress_broadcast_failed class=#{error.class} message=#{error.message}")
      end

      def broadcast_action(deletion_action:, correlation_id:)
        ActionCable.server.broadcast(
          STREAM,
          {
            event: "deletion_action.updated",
            id: deletion_action.id,
            deletion_run_id: deletion_action.deletion_run_id,
            media_file_id: deletion_action.media_file_id,
            status: deletion_action.status,
            error_code: deletion_action.error_code,
            correlation_id: correlation_id
          }
        )
        broadcast_runs_snapshot
        broadcast_run_snapshot(deletion_run_id: deletion_action.deletion_run_id)
      rescue StandardError => error
        Rails.logger.warn("deletion_action_progress_broadcast_failed class=#{error.class} message=#{error.message}")
      end

      private

      def broadcast_runs_snapshot
        recent_deletion_runs = DeletionRun.includes(:deletion_actions).recent_first.limit(20)
        deletion_summary_by_run_id = DeletionRun.action_summary_by_run_id(recent_deletion_runs.map(&:id))

        Turbo::StreamsChannel.broadcast_update_to(
          STREAM,
          target: RUNS_TARGET,
          html: ApplicationController.render(
            partial: "runs/deletion_runs_snapshot",
            locals: {
              running_deletion_run: DeletionRun.where(status: "running").recent_first.first,
              recent_deletion_runs: recent_deletion_runs,
              deletion_summary_by_run_id: deletion_summary_by_run_id
            }
          )
        )
      end

      def broadcast_run_snapshot(deletion_run_id:)
        deletion_run = DeletionRun.includes(deletion_actions: :media_file).find_by(id: deletion_run_id)
        return if deletion_run.blank?

        Turbo::StreamsChannel.broadcast_update_to(
          STREAM,
          target: RUN_TARGET,
          html: ApplicationController.render(
            partial: "deletion_runs/run_snapshot",
            locals: { deletion_run: deletion_run }
          )
        )
      end
    end
  end
end
