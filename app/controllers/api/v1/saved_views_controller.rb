module Api
  module V1
    class SavedViewsController < BaseController
      class InvalidSavedViewPayloadError < StandardError; end

      before_action :set_saved_view, only: :update

      def index
        render json: { saved_views: SavedView.order(:name).map(&:as_api_json) }
      end

      def create
        saved_view = SavedView.new(saved_view_attributes)
        saved_view.save!

        render json: { saved_view: saved_view.as_api_json }, status: :created
      rescue ActionController::ParameterMissing
        render_validation_error(fields: { saved_view: [ "is required" ] })
      rescue InvalidSavedViewPayloadError
        render_validation_error(fields: { saved_view: [ "must be an object" ] })
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def update
        @saved_view.update!(saved_view_attributes)
        render json: { saved_view: @saved_view.as_api_json }
      rescue ActionController::ParameterMissing
        render_validation_error(fields: { saved_view: [ "is required" ] })
      rescue InvalidSavedViewPayloadError
        render_validation_error(fields: { saved_view: [ "must be an object" ] })
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      private

      def set_saved_view
        @saved_view = SavedView.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Saved view not found.", status: :not_found)
      end

      def saved_view_attributes
        payload = params.require(:saved_view)
        payload_hash = extract_payload_hash(payload)
        normalized_payload = payload_hash.deep_stringify_keys

        {
          name: normalized_payload["name"],
          scope: normalized_payload["scope"],
          filters_json: normalized_payload["filters"] || {}
        }
      end

      def extract_payload_hash(payload)
        return payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
        return payload if payload.is_a?(Hash)

        raise InvalidSavedViewPayloadError
      end
    end
  end
end
