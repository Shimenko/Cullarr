class ApplicationController < ActionController::Base
  before_action :set_correlation_id
  before_action :require_login
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_invalid_authenticity_token

  helper_method :current_operator, :operator_signed_in?, :reauthenticated_recently?

  private

  def current_operator
    @current_operator ||= Operator.find_by(id: session[:operator_id])
  end

  def operator_signed_in?
    current_operator.present?
  end

  def require_login
    return if operator_signed_in?

    if request.format.json?
      render json: error_envelope(code: "unauthenticated", message: "Authentication is required."),
             status: :unauthorized
    else
      redirect_to new_session_path, alert: "Sign in is required."
    end
  end

  def set_correlation_id
    @correlation_id = request.request_id
    response.set_header("X-Correlation-Id", @correlation_id)
  end

  def mark_recent_reauthentication!
    session[:reauthenticated_at] = Time.current.to_i
  end

  def clear_reauthentication!
    session.delete(:reauthenticated_at)
  end

  def reauthenticated_recently?
    timestamp = session[:reauthenticated_at]
    return false if timestamp.blank?

    Time.at(timestamp) >= reauthentication_window.ago
  end

  def error_envelope(code:, message:, details: {})
    {
      error: {
        code:,
        message:,
        correlation_id: @correlation_id,
        details:
      }
    }
  end

  def reauthentication_window
    minutes = AppSetting.db_value_for("sensitive_action_reauthentication_window_minutes").to_i
    minutes = 15 if minutes <= 0
    minutes.minutes
  rescue ActiveRecord::ActiveRecordError, KeyError
    15.minutes
  end

  def handle_invalid_authenticity_token
    @correlation_id ||= request.request_id
    response.set_header("X-Correlation-Id", @correlation_id)

    if request.format.json?
      render json: error_envelope(code: "csrf_invalid", message: "CSRF verification failed."),
             status: :forbidden
    else
      reset_session
      redirect_to new_session_path, alert: "Your session has expired. Sign in and try again."
    end
  end
end
