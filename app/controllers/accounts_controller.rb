# The signed-in user's own account: the handle, the password and the
# second factor.
class AccountsController < ApplicationController
  allow_admin_without_second_factor only: %i[ show start_otp confirm_otp ]
  layout "plain"

  def show
    @user = current_user
    # While a secret waits for its confirming code the page shows it (and
    # its QR code): keep it out of the browser's and any proxy's cache.
    response.headers["Cache-Control"] = "no-store" if @user.otp_secret.present? && !@user.otp_enabled?
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

  # The handle (User#handle): what the user's browser pages join the
  # network as. A page open now keeps its node ID until it closes.
  def update_handle
    @user = current_user
    old = @user.handle
    if @user.update(handle: params[:handle].to_s)
      Rails.logger.info("account: user #{@user.id} handle #{old.inspect} -> #{@user.handle.inspect}")
      redirect_to account_path(anchor: "handle"), notice: "Handle set: your browser pages join as " \
                                                          "#{Relay::BrowserNode.base(@user)}."
    else
      redirect_to account_path(anchor: "handle"), alert: "Handle: #{@user.errors[:handle].to_sentence}"
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
    if current_user.admin? && ConsoleAdmin.totp_required?
      return redirect_to account_path, alert: "An admin needs two-factor sign-in; it cannot be turned off."
    end
    unless current_user.authenticate(params[:current_password].to_s)
      return redirect_to account_path, alert: "The current password did not match."
    end
    current_user.disable_otp!
    redirect_to account_path, notice: "Two-factor sign-in is off."
  end
end
