module Deletion
  class RunStatusBroadcaster
    STREAM = "deletion_runs".freeze

    class << self
      def broadcast_run(deletion_run:, correlation_id:)
        ActionCable.server.broadcast(
          STREAM,
          {
            event: "deletion_run.updated",
            id: deletion_run.id,
            status: deletion_run.status,
            summary: deletion_run.as_api_json[:summary],
            correlation_id: correlation_id
          }
        )
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
      rescue StandardError => error
        Rails.logger.warn("deletion_action_progress_broadcast_failed class=#{error.class} message=#{error.message}")
      end
    end
  end
end
