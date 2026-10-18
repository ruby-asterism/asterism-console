module Admin
  # Invite links to make rooms (0.3.5, RoomInvite, docs/rooms.md "Invite
  # links"): an admin makes one (shown whole once), sees what was made
  # through it, changes its message and revokes it. They are listed on the
  # rooms' page.
  class RoomInvitesController < ApplicationController
    require_admin
    layout "plain"
    before_action :set_invite, only: %i[show update revoke]
    rate_limit to: 30, within: 10.minutes, only: :create, by: -> { current_user.id }, store: RateLimits::STORE,
               with: -> { redirect_to admin_rooms_path, alert: "Too many invite links: wait a few minutes." }

    def index
      redirect_to admin_rooms_path(anchor: "invites")
    end

    def create
      p = params.fetch(:room_invite, {})
      @invite = RoomInvite.issue!(by: current_user, name: p[:name], days: p[:days], max_rooms: p[:max_rooms],
                                  apps: Array(p[:apps]), message: p[:message])
      Rails.logger.info("rooms: #{current_user.log_name} made invite link #{@invite.id} (#{@invite.name}) " \
                        "until #{@invite.expires_at.utc.iso8601}, #{@invite.max_rooms} rooms at once")
      @link = invite_page_url(anchor: "invite=#{@invite.token}")
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "same-origin" # no-referrer would post the revoke form with "Origin: null"
      show_page(status: :created)
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to admin_rooms_path(anchor: "invites"), alert: "No invite link made: #{e.message}"
    end

    def show
      show_page
    end

    # Changes its message (the page shows the new one at once), also when it
    # is revoked or expired.
    def update
      if @invite.update(message: params.dig(:room_invite, :message))
        Rails.logger.info("rooms: #{current_user.log_name} changed the message of invite link #{@invite.id}")
        redirect_to admin_room_invite_path(@invite), status: :see_other, notice: "Message saved."
      else
        flash.now[:alert] = "Message not saved: #{@invite.errors.full_messages.to_sentence}"
        show_page(status: :unprocessable_content)
      end
    end

    # Revokes the link (its page stops working at once); its open rooms go
    # on until they end unless the admin closes them too.
    def revoke
      @invite.revoke!(current_user)
      closed = []
      if params[:close_rooms] == "1"
        @invite.open_rooms.each do |r|
          r.close!(current_user, reason: "its invite link was revoked")
          closed << r
        end
        Relay::RoomFiles.write! if closed.any?
      end
      Rails.logger.info("rooms: #{current_user.log_name} revoked invite link #{@invite.id}" \
                        "#{", closing #{closed.size} rooms" if closed.any?}")
      redirect_to admin_room_invite_path(@invite), status: :see_other,
                                                   notice: "Revoked#{" and closed #{closed.size} rooms" if closed.any?}."
    rescue SystemCallError => e
      redirect_to admin_room_invite_path(@invite), status: :see_other, alert: "Revoked, but the door's file: #{e.message}"
    end

    private

    def set_invite
      @invite = RoomInvite.find(params[:id])
    end

    def show_page(status: :ok)
      @rooms = @invite.rooms.includes(:closed_by).order(id: :desc).limit(100)
      render :show, status: status
    end
  end
end
