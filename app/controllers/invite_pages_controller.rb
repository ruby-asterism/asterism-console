# The page of an invite link (0.3.5, RoomInvite, docs/rooms.md "Invite
# links"): someone without an account makes rooms here, and does nothing
# else. The link is /invite#invite=<secret>; the page's script hands the
# secret to #enter in a form's body (a fragment never reaches a server, and
# a body never reaches nginx's log; Rails filters the "token" parameter),
# then this browser's session holds which invite link it opened, until the
# link ends or is revoked. That session is not a sign-in: no other page of
# the console takes it.
#
# Guessing secrets: the secret is 256 bits, and like the rooms' door
# (Relay::RoomDoor) an address that sends BAD_LIMIT secrets that are no
# invite link's within BAD_WINDOW is refused (429) until the window has
# passed; every try is limited too (rate_limit), and nginx limits the rate
# of requests to /invite in front of this.
class InvitePagesController < ApplicationController
  allow_unauthenticated_access
  layout "invite"

  BAD_LIMIT = 10
  BAD_WINDOW = 10.minutes

  rate_limit to: 30, within: 10.minutes, only: :enter, store: RateLimits::STORE, name: "invite_enter",
             with: -> { refuse_too_many }
  rate_limit to: 20, within: 10.minutes, only: %i[create_room close_room], store: RateLimits::STORE, name: "invite_rooms",
             with: -> { refuse_too_many }

  before_action :no_store
  before_action :require_open_invite, only: %i[create_room close_room]

  def show
    @invite = current_invite
    return render :enter unless @invite
    return closed(@invite) unless @invite.open?
    page
  end

  # The secret from the link (or pasted): remembers the invite link in
  # this browser's session.
  def enter
    return refuse_too_many if bad_tries >= BAD_LIMIT
    invite = RoomInvite.find_by_secret(secret_param)
    unless invite
      count_bad_try
      @error = "This is not an invite link (or not a whole one). Check the link you were given."
      return render :enter, status: :not_found
    end
    return closed(invite) unless invite.open?
    session[:room_invite_id] = invite.id
    redirect_to invite_page_path, status: :see_other
  end

  # Forgets the invite link in this browser.
  def leave
    session.delete(:room_invite_id)
    redirect_to invite_page_path, status: :see_other
  end

  def create_room
    p = params.fetch(:room, {})
    @room = @invite.open_room!(name: p[:name], app: p[:app], hours: p[:hours])
    write_files
    Rails.logger.info("rooms: invite link #{@invite.id} (#{@invite.name}) opened room #{@room.uid} (#{@room.name}) " \
                      "on slot #{@room.slot} until #{@room.expires_at.utc.iso8601}")
    @token = @room.mint_key!
    @link = RoomPage.url(room: @token, app: @room.app.to_s)
    # same-origin, not no-referrer: with no-referrer a browser posts the
    # page's forms with "Origin: null", which the forgery protection
    # refuses. The room's key is in the link's fragment, never in a referrer.
    response.headers["Referrer-Policy"] = "same-origin"
    page(status: :created)
  rescue RoomInvite::Refused => e
    refused(e.message)
  rescue Room::Full
    refused("Every room is in use right now: try again when one has ended.")
  rescue ArgumentError, ActiveRecord::RecordInvalid, Relay::SignerClient::Error => e
    refused("No room made: #{e.message}")
  end

  # Closes one of the rooms of this invite link (no other room is found).
  def close_room
    room = @invite.rooms.find_by(id: params[:id])
    return refused("That is not a room of this invite link.", status: :not_found) unless room
    room.close!(nil, reason: "closed on the invite link's page")
    write_files
    Rails.logger.info("rooms: invite link #{@invite.id} closed room #{room.uid} (slot #{room.slot})")
    redirect_to invite_page_path, status: :see_other, notice: "Closed the room #{room.name}."
  end

  private

  def current_invite
    id = session[:room_invite_id]
    id && RoomInvite.find_by(id: id)
  end

  def require_open_invite
    @invite = current_invite
    return render(:enter, status: :forbidden) unless @invite
    closed(@invite) unless @invite.open?
  end

  def page(status: :ok)
    @rooms = @invite.rooms.order(id: :desc).limit(30)
    @open_count = @invite.open_rooms.count
    @apps = @invite.app_choices
    @max_hours = RoomInvite.max_hours
    @default_hours = RoomInvite.default_hours
    render :show, status: status
  end

  def refused(message, status: :unprocessable_content)
    @error = message
    page(status: status)
  end

  def closed(invite)
    session.delete(:room_invite_id)
    @reason = invite.closed_reason
    render :closed, status: :forbidden
  end

  def secret_param
    text = params[:token].to_s.strip
    text[/(?:\A|[#&])invite=([A-Za-z0-9_-]+)/, 1] || text
  end

  def bad_key = "invite-bad:#{request.remote_ip}"

  def bad_tries = RateLimits::STORE.read(bad_key).to_i

  def count_bad_try
    n = RateLimits::STORE.increment(bad_key, 1, expires_in: BAD_WINDOW)
    return unless n.to_i == BAD_LIMIT
    Rails.logger.warn("rooms: #{request.remote_ip} sent #{n} secrets that are no invite link's: " \
                      "refusing its tries for #{BAD_WINDOW.inspect}")
  end

  def refuse_too_many
    @error = "Too many tries from your address: wait a few minutes."
    render :enter, status: :too_many_requests
  end

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end

  def write_files
    Relay::RoomFiles.write!
  rescue SystemCallError => e
    Rails.logger.error("rooms: the door's file could not be written (#{e.message})")
  end
end
