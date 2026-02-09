module Api
  module V1
    class PathMappingsController < BaseController
      before_action :set_integration
      before_action :set_path_mapping, only: %i[update destroy]

      def index
        render json: { path_mappings: @integration.path_mappings.order(:from_prefix).map { |mapping| serialize(mapping) } }
      end

      def create
        mapping = @integration.path_mappings.create!(path_mapping_params)
        record_event("cullarr.integration.updated", mapping, action: "path_mapping_created")
        render json: { path_mapping: serialize(mapping) }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def update
        @path_mapping.update!(path_mapping_params)
        record_event("cullarr.integration.updated", @path_mapping, action: "path_mapping_updated")
        render json: { path_mapping: serialize(@path_mapping) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def destroy
        @path_mapping.destroy!
        record_event("cullarr.integration.updated", @path_mapping, action: "path_mapping_deleted")
        render json: { ok: true }
      end

      private

      def set_integration
        @integration = Integration.find(params[:integration_id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Integration not found.", status: :not_found)
      end

      def set_path_mapping
        @path_mapping = @integration.path_mappings.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Path mapping not found.", status: :not_found)
      end

      def path_mapping_params
        params.require(:path_mapping).permit(:from_prefix, :to_prefix, :enabled)
      end

      def serialize(mapping)
        {
          id: mapping.id,
          from_prefix: mapping.from_prefix,
          to_prefix: mapping.to_prefix,
          enabled: mapping.enabled
        }
      end

      def record_event(event_name, subject, action:)
        AuditEvents::Recorder.record!(
          event_name: event_name,
          correlation_id: request.request_id,
          actor: current_operator,
          subject: subject,
          payload: { action: action }
        )
      end
    end
  end
end
