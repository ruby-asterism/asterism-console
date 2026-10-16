# What the door needs to know about the rooms (G2, docs/rooms.md), in one
# file it reads again when it changes (Relay::Settings.rooms_dir,
# rooms.json):
#
#   {"format": 1, "written_at": "...",
#    "keys":    [{"kid": "...", "public_key": "<PEM>"}],     the signer's public keys
#    "slots":   {"01": {"room": "<uid>", "until": <Unix s>, "max": 16, "app": "/app/...", "seats": 16}},
#    "revoked": [{"room": "<uid>", "until": <Unix s>}],
#    "seat_node_prefix": "wasm-", "hosts": ["games"]}
#
# "seats" (0.3.0, docs/rooms.md "Seats"): how many seats of the slot the
# router's configuration (the generated cloud.json5) lets in, 0 when none
# (not applied yet: the console offers such a slot to no room). The door
# gives the browsers of a room a seat each and connects with the seat's
# certificate; a slot without seats lets nobody in. A seat's node ID is
# seat_node_prefix, the slot and the seat
# (wasm-0103). "hosts": the game hosts that join the rooms with their own
# certificates (ASTERISM_ROOM_HOSTS), whose node IDs (<host>$*) nobody in a
# room can write under or call as. A game host reads both to know which
# callers the router has bound to their names.
#
# A key passes the door only when its signature checks with one of the
# keys, it has not ended, its slot holds its room now, and its room is not
# revoked (closed early). "slots" lists the open rooms only, so a closed
# room has left its slot too; "revoked" says so explicitly until the
# room's keys would have ended anyway. When the file is missing or
# unreadable the door lets no room in.
#
# "app" is what the room's link opens (the door does not use it): a game
# host that reads this file (asterism-games, mounting the volume read-only)
# serves tables in the rooms that open its table's screen.
#
# Written after every change to the rooms (Room callbacks) and when the
# admin pages show the rooms. The public keys are asked of the signer each
# time; when it does not answer, the keys already in the file are kept.
require "json"
require "fileutils"

module Relay
  module RoomFiles
    module_function

    def path(env = ENV)
      File.join(Settings.rooms_dir(env), "rooms.json")
    end

    def content(at: Time.current, keys: nil, seats: seats_in_config)
      open_rooms = Room.open_now(at).order(:id).to_a
      slots = open_rooms.to_h { [ _1.slot, { "room" => _1.uid, "until" => _1.expires_at.to_i, "max" => _1.max_connections,
                                            "app" => _1.app.to_s, "seats" => seats.fetch(_1.slot, 0) } ] }
      revoked = Room.where.not(closed_at: nil).where("expires_at > ?", at).order(:id)
                    .map { { "room" => _1.uid, "until" => _1.expires_at.to_i } }
      { "format" => 1, "written_at" => at.utc.iso8601, "keys" => keys || public_keys, "slots" => slots,
        "revoked" => revoked, "seat_node_prefix" => Settings.browser_node_prefix, "hosts" => Settings.room_hosts }
    end

    # {slot => seats}: the seats 01 .. n of each slot that the router's
    # configuration file lets in (all of them, in order: a gap stops the
    # count, so the door never hands out a seat the router refuses).
    def seats_in_config(path = Settings.config_path)
      names = CloudConfig.subjects_of(File.exist?(path) ? File.read(path) : nil) || []
      wanted = Settings.seat_names
      Settings.slot_names.to_h do |slot|
        n = wanted.take_while { names.include?(Settings.seat_peer_name(slot, _1)) }.size
        [ slot, n ]
      end.select { _2.positive? }
    end

    # The signer's public keys, or the ones in the file now.
    def public_keys(signer: Room.signer_client)
      signer.room_keys["keys"].map { _1.slice("kid", "public_key") }
    rescue SignerClient::Error => e
      Rails.logger.warn("rooms: the signer's public keys: #{e.message}; keeping the ones in #{path}")
      current_keys
    end

    def current_keys
      JSON.parse(File.read(path)).fetch("keys", [])
    rescue SystemCallError, JSON::ParserError
      []
    end

    def write!(**opts)
      text = JSON.pretty_generate(content(**opts)) + "\n"
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp#{Process.pid}"
      File.write(tmp, text)
      File.chmod(0o644, tmp)
      File.rename(tmp, path)
      text
    end
  end
end
