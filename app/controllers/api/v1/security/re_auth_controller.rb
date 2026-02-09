module Api
  module V1
    module Security
      class ReAuthController < BaseController
        def create
          if current_operator.authenticate(params.require(:password))
            mark_recent_reauthentication!
            AuditEvents::Recorder.record_without_subject!(
              event_name: "cullarr.security.re_authenticated",
              correlation_id: request.request_id,
              actor: current_operator
            )

            render json: { re_authenticated: true, expires_at: reauthentication_window.from_now }
          else
            AuditEvents::Recorder.record_without_subject!(
              event_name: "cullarr.security.delete_unlock_denied",
              correlation_id: request.request_id,
              actor: current_operator
            )
            render_api_error(code: "forbidden", message: "Password verification failed.", status: :forbidden)
          end
        rescue ActionController::ParameterMissing
          render_validation_error(fields: { password: [ "is required" ] })
        end
      end
    end
  end
end
