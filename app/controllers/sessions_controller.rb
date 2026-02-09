class SessionsController < ApplicationController
  skip_before_action :require_login, only: %i[new create]

  def new
    redirect_to root_path if operator_signed_in?

    @operator = Operator.new
    @bootstrap_mode = !Operator.exists?
  end

  def create
    return bootstrap_first_operator if bootstrap_mode?

    authenticate_existing_operator
  end

  def destroy
    clear_reauthentication!
    reset_session
    redirect_to new_session_path, notice: "Signed out."
  end

  private

  def bootstrap_mode?
    !Operator.exists?
  end

  def bootstrap_first_operator
    operator = Operator.new(registration_params)
    @operator = operator
    @bootstrap_mode = true

    if operator.save
      sign_in(operator)
      redirect_to root_path, notice: "Operator account created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def authenticate_existing_operator
    @bootstrap_mode = false
    email = login_params[:email].to_s.strip.downcase
    operator = Operator.find_by(email:)

    if operator && operator.authenticate(login_params[:password])
      sign_in(operator)
      redirect_to root_path, notice: "Signed in."
    else
      @operator = Operator.new(email:)
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_content
    end
  end

  def sign_in(operator)
    clear_reauthentication!
    reset_session
    session[:operator_id] = operator.id
    operator.update!(last_login_at: Time.current)
  end

  def login_params
    params.require(:session).permit(:email, :password)
  end

  def registration_params
    params.require(:operator).permit(:email, :password, :password_confirmation)
  end
end
