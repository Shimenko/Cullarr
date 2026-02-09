class ApplicationController < ActionController::Base
  before_action :set_correlation_id
  before_action :require_login

  helper_method :current_operator, :operator_signed_in?

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
end
