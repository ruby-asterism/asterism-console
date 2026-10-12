module Admin
  # Making and revoking invitations (W4). The link is shown once.
  class InvitationsController < ApplicationController
    require_admin
    layout "plain"

    def index
      redirect_to admin_users_path
    end

    def create
      inv = Invitation.issue!(by: current_user, note: params[:note], admin: params[:admin] == "1")
      Rails.logger.info("invitation: #{inv.id} made by #{current_user.email_address}#{' (admin)' if inv.admin?}")
      @new_link = invitation_url(inv.token)
      @new_invitation = inv
      @users = User.order(:email_address)
      @invitations = Invitation.includes(:created_by, :user).order(id: :desc).limit(50)
      response.headers["Cache-Control"] = "no-store"
      render "admin/users/index", status: :created
    end

    def revoke
      Invitation.find(params[:id]).revoke!
      redirect_to admin_users_path, status: :see_other, notice: "Revoked."
    end
  end
end
