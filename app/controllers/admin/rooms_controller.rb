module Admin
  # Rooms (G2, docs/rooms.md): an admin makes one, gets its link (once),
  # makes another link, watches its connections and closes it. Making or
  # closing a room restarts nothing: it takes a slot whose seats'
  # certificates and ACL are made already, and the door learns of it from
  # the rooms' file (Relay::RoomFiles), which every change here writes
  # again.
  class RoomsController < ApplicationController
    require_admin
    layout "plain"
    before_action :set_room, only: %i[show link destroy]
    rate_limit to: 30, within: 10.minutes, only: %i[create link], by: -> { current_user.id }, store: RateLimits::STORE,
               with: -> { redirect_to admin_rooms_path, alert: "Too many rooms or links: wait a few minutes." }

    def index
      write_files
      @rooms = Room.includes(:created_by, :closed_by, :room_invite).order(id: :desc).limit(100)
      @invites = RoomInvite.includes(:created_by).order(id: :desc).limit(50)
      @door = Relay::DoorStatus.fetch
      @seats_in_config = Relay::RoomFiles.seats_in_config
      @ready = Room.ready_slots(@seats_in_config)
      @slots = Relay::Settings.slot_names
      @busy = Room.open_now.index_by(&:slot)
      # The seats (0.3.0) are the rooms' own (0.3.1): their certificates in
      # the rooms' store, not the registry; shown here.
      @seat_certs = Relay::RoomCerts.summary
      @room = Room.new(max_connections: Relay::Settings.room_max_connections)
      @hours, @max_hours = Relay::Settings.room_hours
      @apps = RoomPage.apps
      games
    end

    def create
      app = params.dig(:room, :app_other).to_s.strip.presence || params.dig(:room, :app)
      @room = Room.open!(name: params.dig(:room, :name), app: app, hours: params.dig(:room, :hours),
                         max_connections: params.dig(:room, :max_connections), by: current_user)
      write_files
      Rails.logger.info("rooms: #{current_user.log_name} opened room #{@room.uid} (#{@room.name}) on slot #{@room.slot} " \
                        "until #{@room.expires_at.utc.iso8601}")
      show_link(@room.mint_key!, status: :created)
    rescue Room::Full, ArgumentError, ActiveRecord::RecordInvalid, Relay::SignerClient::Error => e
      redirect_to admin_rooms_path, alert: "No room made: #{e.message}"
    end

    def show
      @door = Relay::DoorStatus.fetch
      games
    end

    # Another link (another key) for an open room.
    def link
      show_link(@room.mint_key!)
    rescue ArgumentError, Relay::SignerClient::Error => e
      redirect_to admin_room_path(@room), alert: "No link made: #{e.message}"
    end

    # Closes the room: its keys are refused and its connections cut by the
    # door within a second. The record stays (the list shows it).
    def destroy
      @room.close!(current_user)
      write_files
      Rails.logger.info("rooms: #{current_user.log_name} closed room #{@room.uid} (slot #{@room.slot})")
      redirect_to admin_rooms_path, status: :see_other,
                                    notice: "Closed the room #{@room.name}. The door cuts its connections within a second."
    end

    private

    def set_room
      @room = Room.find(params[:id])
    end

    # The game host's status (Relay::GamesStatus), when one is set.
    def games
      @games_on = Relay::GamesStatus.configured?
      @games = @games_on ? Relay::GamesStatus.fetch : nil
      @games_apps = @games_on ? Array(@games&.dig("apps")) : []
    end

    def write_files
      Relay::RoomFiles.write!
    rescue SystemCallError => e
      flash.now[:alert] = "The door's file could not be written (#{e.message}): #{Relay::RoomFiles.path}"
    end

    # The key in a page that is not kept (no redirect: the log would show it).
    def show_link(token, status: :ok)
      @token = token
      @link = RoomPage.url(room: token, app: @room.app.to_s)
      @door = Relay::DoorStatus.fetch
      games
      response.headers["Cache-Control"] = "no-store"
      # same-origin, not no-referrer: the page posts its own forms (another
      # link, closing the room), and with no-referrer a browser sends them
      # with "Origin: null", which the forgery check refuses (422).
      response.headers["Referrer-Policy"] = "same-origin"
      render :show, status: status
    end
  end
end
