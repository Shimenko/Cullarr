module Api
  module V1
    class PathExclusionsController < BaseController
      before_action :set_path_exclusion, only: %i[update destroy]

      def index
        exclusions = PathExclusion.order(:path_prefix).map do |exclusion|
          { id: exclusion.id, name: exclusion.name, path_prefix: exclusion.path_prefix, enabled: exclusion.enabled }
        end

        render json: { path_exclusions: exclusions }
      end

      def create
        exclusion = PathExclusion.create!(path_exclusion_params)
        record_event(exclusion, "created")
        render json: { path_exclusion: serialize(exclusion) }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def update
        @path_exclusion.update!(path_exclusion_params)
        record_event(@path_exclusion, "updated")
        render json: { path_exclusion: serialize(@path_exclusion) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def destroy
        @path_exclusion.destroy!
        record_event(@path_exclusion, "deleted")
        render json: { ok: true }
      end

      private

      def set_path_exclusion
        @path_exclusion = PathExclusion.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Path exclusion not found.", status: :not_found)
      end

      def path_exclusion_params
        params.require(:path_exclusion).permit(:name, :path_prefix, :enabled)
      end

      def serialize(exclusion)
        {
          id: exclusion.id,
          name: exclusion.name,
          path_prefix: exclusion.path_prefix,
          enabled: exclusion.enabled
        }
      end

      def record_event(exclusion, action)
        AuditEvents::Recorder.record!(
          event_name: "cullarr.settings.updated",
          correlation_id: request.request_id,
          actor: current_operator,
          subject: exclusion,
          payload: { action: "path_exclusion_#{action}" }
        )
      end
    end
  end
end
