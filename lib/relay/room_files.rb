# What the door needs to know about the rooms (G2, docs/rooms.md), in one
# file it reads again when it changes (Relay::Settings.rooms_dir,
# rooms.json):
#
#   {"format": 1, "written_at": "...",
#    "keys":    [{"kid": "...", "public_key": "<PEM>"}],     the signer's public keys
#    "slots":   {"01": {"room": "<uid>", "until": <Unix s>, "max": 16, "app": "/app/..."}},
#    "revoked": [{"room": "<uid>", "until": <Unix s>}]}
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

    def content(at: Time.current, keys: nil)
      open_rooms = Room.open_now(at).order(:id).to_a
      slots = open_rooms.to_h { [ _1.slot, { "room" => _1.uid, "until" => _1.expires_at.to_i, "max" => _1.max_connections,
                                            "app" => _1.app.to_s } ] }
      revoked = Room.where.not(closed_at: nil).where("expires_at > ?", at).order(:id)
                    .map { { "room" => _1.uid, "until" => _1.expires_at.to_i } }
      { "format" => 1, "written_at" => at.utc.iso8601, "keys" => keys || public_keys, "slots" => slots,
        "revoked" => revoked }
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
