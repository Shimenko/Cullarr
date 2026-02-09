module Api
  module V1
    class BaseController < ApplicationController
      prepend_before_action :set_api_version_header
      rescue_from ActionController::ParameterMissing, with: :handle_parameter_missing

      private

      def set_api_version_header
        response.set_header("X-Cullarr-Api-Version", "v1")
      end

      def render_api_error(code:, message:, status:, details: {})
        render json: error_envelope(code:, message:, details:), status:
      end

      def render_validation_error(fields:)
        render_api_error(
          code: "validation_failed",
          message: "One or more fields are invalid.",
          status: :unprocessable_content,
          details: { fields: fields }
        )
      end

      def require_recent_reauthentication!
        return if reauthenticated_recently?

        render_api_error(
          code: "forbidden",
          message: "Recent re-authentication is required for this action.",
          status: :forbidden
        )
      end

      def handle_parameter_missing(error)
        missing_key = error.param.to_s
        missing_key = "base" if missing_key.blank?

        render_validation_error(fields: { missing_key => [ "is required" ] })
      end
    end
  end
end
