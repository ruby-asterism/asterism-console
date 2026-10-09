# Signing in: email address and password, then (for a user who turned it
# on) a TOTP code. The user waiting for a code is kept in the Rails session
# for OTP_WAIT only; nothing is shown or callable before the code.
class SessionsController < ApplicationController
  OTP_WAIT = 5.minutes

  allow_unauthenticated_access only: %i[ new create otp verify_otp ]
  rate_limit to: 10, within: 3.minutes, only: %i[ create verify_otp ],
             with: -> { redirect_to new_session_path, alert: "Try again later." }

  layout "plain"

  def new
  end

  def create
    user = User.authenticate_by(params.permit(:email_address, :password))
    unless user
      return redirect_to new_session_path, alert: "Try another email address or password."
    end
    if user.otp_enabled?
      session[:otp_user_id] = user.id
      session[:otp_until] = OTP_WAIT.from_now.to_i
      redirect_to otp_session_path
    else
      sign_in(user)
    end
  end

  # The second step: the code from the authenticator app.
  def otp
    redirect_to new_session_path unless pending_user
  end

  def verify_otp
    user = pending_user
    return redirect_to new_session_path, alert: "Sign in again." unless user
    if user.verify_otp(params[:code])
      sign_in(user)
    else
      redirect_to otp_session_path, alert: "That code did not match."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private

  def pending_user
    return nil unless session[:otp_user_id] && session[:otp_until].to_i > Time.current.to_i
    User.find_by(id: session[:otp_user_id])
  end

  def sign_in(user)
    url = after_authentication_url
    start_new_session_for(user)
    redirect_to url
  end
end
