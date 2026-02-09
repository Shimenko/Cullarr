module Api
  module V1
    class KeepMarkersController < BaseController
      before_action :set_keep_marker, only: :destroy

      def index
        keep_markers = KeepMarker.order(created_at: :desc).map do |marker|
          {
            id: marker.id,
            keepable_type: marker.keepable_type,
            keepable_id: marker.keepable_id,
            note: marker.note
          }
        end
        render json: { keep_markers: keep_markers }
      end

      def create
        marker = KeepMarker.create!(keep_marker_params)
        record_event(marker, "created")
        render json: { keep_marker: serialize(marker) }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def destroy
        @keep_marker.destroy!
        record_event(@keep_marker, "deleted")
        render json: { ok: true }
      end

      private

      def set_keep_marker
        @keep_marker = KeepMarker.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Keep marker not found.", status: :not_found)
      end

      def keep_marker_params
        params.require(:keep_marker).permit(:keepable_type, :keepable_id, :note)
      end

      def serialize(marker)
        {
          id: marker.id,
          keepable_type: marker.keepable_type,
          keepable_id: marker.keepable_id,
          note: marker.note
        }
      end

      def record_event(marker, action)
        AuditEvents::Recorder.record!(
          event_name: "cullarr.settings.updated",
          correlation_id: request.request_id,
          actor: current_operator,
          subject: marker,
          payload: { action: "keep_marker_#{action}" }
        )
      end
    end
  end
end
