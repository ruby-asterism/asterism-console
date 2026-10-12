module Admin
  # The users (W4): who may sign in, who is an admin, invitations to join.
  # Under /admin (the proxy limits it by address).
  class UsersController < ApplicationController
    require_admin
    layout "plain"

    def index
      @users = User.order(:email_address)
      @invitations = Invitation.includes(:created_by, :user).order(id: :desc).limit(50)
    end

    def update
      user = User.find(params[:id])
      return redirect_to admin_users_path, alert: "You cannot change your own role." if user == current_user
      admin = ActiveModel::Type::Boolean.new.cast(params[:admin])
      user.update!(admin: admin)
      user.sessions.destroy_all
      Rails.logger.info("users: #{user.email_address} admin=#{admin} by #{current_user.email_address}")
      redirect_to admin_users_path, status: :see_other,
                  notice: "#{user.email_address} is #{admin ? 'an admin' : 'a user'} now (signed out everywhere)."
    end

    def destroy
      user = User.find(params[:id])
      return redirect_to admin_users_path, alert: "You cannot remove yourself." if user == current_user
      user.destroy!
      Rails.logger.info("users: removed #{user.email_address} by #{current_user.email_address}")
      redirect_to admin_users_path, status: :see_other, notice: "Removed #{user.email_address}."
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed
      redirect_to admin_users_path, status: :see_other,
                  alert: "#{user.email_address} is still named in records (certificates, applies): not removed."
    end

    def otp_off
      user = User.find(params[:id])
      user.disable_otp!
      user.sessions.destroy_all
      redirect_to admin_users_path, status: :see_other,
                  notice: "Two-factor sign-in is off for #{user.email_address} (signed out everywhere)."
    end
  end
end
