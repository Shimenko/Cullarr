class SecurityController < ApplicationController
  def update_password
    unless current_operator.authenticate(password_params[:current_password])
      return redirect_to settings_path, alert: "Current password is invalid."
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

    redirect_to settings_path, notice: "Password updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def re_authenticate
    if current_operator.authenticate(params.require(:password))
      mark_recent_reauthentication!
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.security.re_authenticated",
        correlation_id: request.request_id,
        actor: current_operator
      )

      redirect_to settings_path, notice: "Re-authentication successful for sensitive actions."
    else
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.security.delete_unlock_denied",
        correlation_id: request.request_id,
        actor: current_operator
      )
      redirect_to settings_path, alert: "Password verification failed."
    end
  rescue ActionController::ParameterMissing
    redirect_to settings_path, alert: "Password is required for re-authentication."
  end

  private

  def password_params
    params.require(:password).permit(:current_password, :password, :password_confirmation)
  end
end
