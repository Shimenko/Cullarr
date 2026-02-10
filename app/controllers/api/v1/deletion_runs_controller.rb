module Api
  module V1
    class DeletionRunsController < BaseController
      before_action :set_deletion_run, only: %i[show cancel]

      def plan
        result = Deletion::PlanDeletionRun.new(
          operator: current_operator,
          unlock_token: params[:unlock_token],
          scope: params[:scope],
          selection: params[:selection],
          version_selection: params[:version_selection],
          plex_user_ids: params[:plex_user_ids],
          correlation_id: request.request_id
        ).call

        if result.success?
          render json: { plan: result.plan }
        else
          render_deletion_error(result)
        end
      end

      def create
        if params.key?(:action_context)
          return render_validation_error(fields: { action_context: [ "must not be provided" ] })
        end

        result = Deletion::CreateDeletionRun.new(
          operator: current_operator,
          unlock_token: params[:unlock_token],
          scope: params[:scope],
          planned_media_file_ids: params[:planned_media_file_ids],
          plex_user_ids: params[:plex_user_ids],
          action_context: nil,
          correlation_id: request.request_id
        ).call

        if result.success?
          Deletion::RunStatusBroadcaster.broadcast_run(deletion_run: result.deletion_run, correlation_id: request.request_id)
          Deletion::ProcessRunJob.perform_later(result.deletion_run.id, request.request_id)
          render json: { deletion_run: { id: result.deletion_run.id, status: result.deletion_run.status } }, status: :accepted
        else
          render_deletion_error(result)
        end
      end

      def show
        render json: { deletion_run: @deletion_run.as_api_json }
      end

      def cancel
        unless @deletion_run.status.in?(%w[queued running])
          return render_api_error(
            code: "conflict",
            message: "Deletion run cannot be canceled in its current state.",
            status: :conflict
          )
        end

        @deletion_run.update!(status: "canceled", finished_at: Time.current)
        AuditEvents::Recorder.record!(
          event_name: "cullarr.deletion.run_canceled",
          correlation_id: request.request_id,
          actor: current_operator,
          subject: @deletion_run,
          payload: {
            deletion_run_id: @deletion_run.id,
            status: @deletion_run.status
          }
        )
        Deletion::RunStatusBroadcaster.broadcast_run(deletion_run: @deletion_run, correlation_id: request.request_id)
        render json: { deletion_run: @deletion_run.as_api_json }
      end

      private

      def set_deletion_run
        @deletion_run = DeletionRun.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Deletion run not found.", status: :not_found)
      end

      def render_deletion_error(result)
        status = case result.error_code
        when "delete_mode_disabled", "delete_unlock_required", "delete_unlock_invalid", "delete_unlock_expired", "forbidden"
          :forbidden
        when "validation_failed", "multi_version_selection_required", /\Aguardrail_/
          :unprocessable_content
        when "conflict"
          :conflict
        else
          :unprocessable_content
        end

        render_api_error(
          code: result.error_code,
          message: result.error_message,
          status: status,
          details: result.respond_to?(:error_details) ? result.error_details || {} : {}
        )
      end
    end
  end
end
