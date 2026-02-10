module Api
  module V1
    module DeleteMode
      class UnlocksController < BaseController
        def create
          result = Deletion::IssueDeleteModeUnlock.new(
            operator: current_operator,
            password: params.require(:password),
            correlation_id: request.request_id
          ).call

          if result.success?
            mark_recent_reauthentication!
            render json: { unlock: { token: result.token, expires_at: result.expires_at } }
          else
            render_api_error(
              code: result.error_code,
              message: result.error_message,
              status: response_status(result.error_code)
            )
          end
        rescue ActionController::ParameterMissing
          render_validation_error(fields: { password: [ "is required" ] })
        end

        private

        def response_status(error_code)
          case error_code
          when "delete_mode_disabled", "forbidden"
            :forbidden
          else
            :unprocessable_content
          end
        end
      end
    end
  end
end
