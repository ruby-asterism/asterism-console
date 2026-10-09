# The signed-in user's own account: the password and the second factor.
class AccountsController < ApplicationController
  layout "plain"

  def show
    @user = current_user
  end

  def update_password
    @user = current_user
    unless @user.authenticate(params[:current_password].to_s)
      return redirect_to account_path, alert: "The current password did not match."
    end
    if @user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      redirect_to account_path, notice: "Password changed."
    else
      redirect_to account_path, alert: @user.errors.full_messages.to_sentence
    end
  end

  # TOTP: a new secret (shown on the page once), then a code to confirm it.
  def start_otp
    current_user.start_otp!
    redirect_to account_path
  end

  def confirm_otp
    if current_user.confirm_otp!(params[:code])
      redirect_to account_path, notice: "Two-factor sign-in is on."
    else
      redirect_to account_path, alert: "That code did not match."
    end
  end

  def disable_otp
    unless current_user.authenticate(params[:current_password].to_s)
      return redirect_to account_path, alert: "The current password did not match."
    end
    current_user.disable_otp!
    redirect_to account_path, notice: "Two-factor sign-in is off."
  end
end
