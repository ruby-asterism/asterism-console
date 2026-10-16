# Where the relay's generated configuration goes and how the cloud router
# is restarted (the environment). The defaults are the layout of
# deploy/vps: the console writes the file and asks for a restart by
# writing restart.request next to it (bin/relay_restart_request), which the
# router's container watches (deploy/vps/zenohd/run.sh). Any router that
# reads the file and restarts on the request works the same way; or set
# ASTERISM_RELAY_RESTART to a command that restarts yours.
#
#   ASTERISM_RELAY_CLOUD_NAME     zenohd-cloud (its metadata/name and certificate name)
#   ASTERISM_RELAY_GENERATED_DIR  storage/relay/generated (cloud.json5 is written there)
#   ASTERISM_RELAY_CERTS_DIR      storage/relay/certs (this server's own router and bridge
#                                 certificates: relay:issue_local, bin/asterism setup)
#   ASTERISM_RELAY_COMPOSE_DIR    the console's directory (where the restart command runs)
#   ASTERISM_RELAY_RESTART        bin/relay_restart_request (e.g. "docker compose restart zenohd")
#
# What goes into the cloud router's configuration (Relay::CloudConfig):
#
#   ASTERISM_RELAY_LISTEN         tls/[::]:7448 (comma separated for more)
#   ASTERISM_RELAY_BROWSERS       a ws/ endpoint (ws/[::]:7449) lets the browser build in,
#                                 behind the proxy that checks passes (W4); unset: none
#   ASTERISM_BROWSER_NODE_PREFIX  wasm- (the browsers' node IDs start with it: ${node} of the
#                                 roles for browsers is <prefix>$*, and the console names a
#                                 browser page it opens <prefix><handle>, Relay::BrowserNode)
#   ASTERISM_RELAY_MAX_SESSIONS   96    (transport/unicast/max_sessions; 64 before G2's rooms)
#   ASTERISM_RELAY_ACCEPT_PENDING 16    (transport/unicast/accept_pending)
#   ASTERISM_RELAY_ACCEPT_TIMEOUT 5000  (ms, transport/unicast/accept_timeout)
#   ASTERISM_RELAY_MAX_MESSAGE    4194304 (bytes, transport/link/rx/max_message_size)
#
# Rooms (G2, docs/rooms.md):
#
#   ASTERISM_ROOM_SLOTS           8     room slots: room-01 .. room-08, each with its certificate and
#                                       its ACL (room/<slot>/**) made once; a room takes a free one
#   ASTERISM_ROOM_DEFAULT_HOURS   3     how long a new room is open unless the admin says otherwise
#   ASTERISM_ROOM_MAX_HOURS       24    the longest (at most 24: the signer refuses a later end)
#   ASTERISM_ROOM_MAX_CONNECTIONS 16    connections a room may have at once (at most 16)
#   ASTERISM_ROOM_SEATS           16    seats per slot (0.3.0): room-NN-s01 .. room-NN-s16, a certificate
#                                       each, node ID <prefix><slot><seat> (wasm-0103); the door gives a
#                                       browser a seat and connects with its certificate, so the router
#                                       binds the page's writes and calls to its own node ID (0: no seats,
#                                       the door uses the slot's certificate as before 0.3.0)
#   ASTERISM_ROOM_HOSTS           games the node IDs of game hosts that join the rooms with their own
#                                       certificate (a registry row of that name): the rooms' tables
#                                       under room/*/asterism/<host>$* are theirs only (comma separated;
#                                       "-": none)
#   ASTERISM_ROOMS_DIR            storage/relay/rooms (what the door reads: rooms.json, the
#                                       slots' certificates in certs/)
#   ASTERISM_DOOR_STATUS_URL      http://127.0.0.1:7453/status (the door's connection counts)
#   ASTERISM_GAMES_STATUS_URL     none (a game host's GET /status, e.g. http://asterism-games:7460/status:
#                                       the rooms' page shows its tables)
#   ASTERISM_ROOM_APPS            none (what a room's link may open, "Label=/path,...", offered first
#                                       on the rooms' page; the roles' browser apps follow)
require "shellwords"

module Relay
  module Settings
    module_function

    def cloud_name(env = ENV)
      env["ASTERISM_RELAY_CLOUD_NAME"].presence || "zenohd-cloud"
    end

    def cloud_settings(env = ENV)
      int = ->(k) { env[k].presence && Integer(env[k]) }
      {
        "name" => cloud_name(env),
        "listen" => env["ASTERISM_RELAY_LISTEN"].presence&.split(",")&.map(&:strip),
        "browsers" => env["ASTERISM_RELAY_BROWSERS"].presence,
        "browser_nodes" => "#{browser_node_prefix(env)}$*",
        "seat_node_prefix" => browser_node_prefix(env),
        "max_sessions" => int.("ASTERISM_RELAY_MAX_SESSIONS"),
        "accept_pending" => int.("ASTERISM_RELAY_ACCEPT_PENDING"),
        "accept_timeout_ms" => int.("ASTERISM_RELAY_ACCEPT_TIMEOUT"),
        "max_message_size" => int.("ASTERISM_RELAY_MAX_MESSAGE"),
        "room_seats" => room_seats(env),
        "room_hosts" => room_hosts(env)
      }.compact
    end

    def room_slots(env = ENV)
      n = Integer(env["ASTERISM_ROOM_SLOTS"].presence || 8)
      raise ArgumentError, "ASTERISM_ROOM_SLOTS must be 0..99" unless n.between?(0, 99)
      n
    end

    # The slots' names: "01" .. "08".
    def slot_names(env = ENV)
      (1..room_slots(env)).map { format("%02d", _1) }
    end

    def slot_peer_name(slot) = "room-#{slot}"

    # Seats per slot (0.3.0, docs/rooms.md "Seats").
    def room_seats(env = ENV)
      n = Integer(env["ASTERISM_ROOM_SEATS"].presence || 16)
      raise ArgumentError, "ASTERISM_ROOM_SEATS must be 0..99" unless n.between?(0, 99)
      n
    end

    # The seats' names: "01" .. "16".
    def seat_names(env = ENV)
      (1..room_seats(env)).map { format("%02d", _1) }
    end

    def seat_peer_name(slot, seat) = "room-#{slot}-s#{seat}"

    # A seat's node ID: the browsers' prefix, the slot and the seat (wasm-0103).
    def seat_node(slot, seat, prefix = browser_node_prefix) = "#{prefix}#{slot}#{seat}"

    # The game hosts that join the rooms with their own certificates.
    def room_hosts(env = ENV)
      text = env["ASTERISM_ROOM_HOSTS"]
      return [ "games" ] if text.nil? || text.strip.empty?
      return [] if text.strip == "-"
      names = text.split(",").map(&:strip).reject(&:empty?).uniq
      bad = names.reject { CertAuthority::NAME_RE.match?(_1) }
      raise ArgumentError, "ASTERISM_ROOM_HOSTS: not node IDs: #{bad.join(', ')}" if bad.any?
      names
    end

    def room_hours(env = ENV)
      max = Integer(env["ASTERISM_ROOM_MAX_HOURS"].presence || RoomToken::MAX_HOURS).clamp(1, RoomToken::MAX_HOURS)
      default = Integer(env["ASTERISM_ROOM_DEFAULT_HOURS"].presence || 3).clamp(1, max)
      [ default, max ]
    end

    def room_max_connections(env = ENV)
      Integer(env["ASTERISM_ROOM_MAX_CONNECTIONS"].presence || RoomToken::MAX_CONNECTIONS).clamp(1, RoomToken::MAX_CONNECTIONS)
    end

    def rooms_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_ROOMS_DIR"].presence || "storage/relay/rooms", root)
    end

    def door_status_url(env = ENV)
      env["ASTERISM_DOOR_STATUS_URL"].presence || "http://127.0.0.1:7453/status"
    end

    # A game host next to the console (asterism-games, its GET /status):
    # the rooms' page shows its tables. nil: no game host.
    def games_status_url(env = ENV)
      env["ASTERISM_GAMES_STATUS_URL"].presence
    end

    def browser_node_prefix(env = ENV)
      prefix = env["ASTERISM_BROWSER_NODE_PREFIX"].presence || "wasm-"
      raise ArgumentError, "ASTERISM_BROWSER_NODE_PREFIX: #{prefix.inspect}" unless prefix.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,20}\z/)
      prefix
    end

    def generated_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_GENERATED_DIR"].presence || "storage/relay/generated", root)
    end

    def certs_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_CERTS_DIR"].presence || "storage/relay/certs", root)
    end

    def config_path(env = ENV, root: Rails.root)
      File.join(generated_dir(env, root: root), "cloud.json5")
    end

    def compose_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_COMPOSE_DIR"].presence || ".", root)
    end

    def restart_command(env = ENV, root: Rails.root)
      cmd = env["ASTERISM_RELAY_RESTART"].presence or return [ File.join(root.to_s, "bin/relay_restart_request") ]
      Shellwords.split(cmd)
    end
  end
end
