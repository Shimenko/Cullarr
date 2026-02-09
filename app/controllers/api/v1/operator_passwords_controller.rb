module Api
  module V1
    class OperatorPasswordsController < BaseController
      def update
        unless current_operator.authenticate(password_params[:current_password])
          return render_api_error(code: "forbidden", message: "Current password is invalid.", status: :forbidden)
        end

        current_operator.update!(
          password: password_params[:password],
          password_confirmation: password_params[:password_confirmation]
        )
        clear_reauthentication!
        AuditEvents::Recorder.record_without_subject!(
          event_name: "cullarr.security.password_changed",
          correlation_id: request.request_id,
          actor: current_operator
        )

        render json: { ok: true }
      rescue ActionController::ParameterMissing
        render_validation_error(fields: { password: [ "is required" ] })
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      private

      def password_params
        params.require(:password).permit(:current_password, :password, :password_confirmation)
      end
    end
  end
end
