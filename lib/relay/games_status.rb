# A game host's status (asterism-games next to the console, README "Rooms"
# there), for the rooms' admin page: what it answers on GET /status.
#
#   {"version": "0.3.0", "since": "...", "max": 3, "apps": ["/app/..."],
#    "rooms": {"01": {"room": "<uid>", "state": "up", "restarts": 0,
#                     "tables": {"mahjong1": {"st": "play", "humans": 3, "cpus": 1, "members": 5, "away": 0}}}},
#    "without_table": ["03"],
#    "permanent": {"node": "games", "state": "up", "restarts": 0, "table_names": ["mahjong1", "mahjong2"],
#                  "tables": {"mahjong1": {...}, "mahjong2": {...}}},
#    "busy": true, "rss_kb": 123456}
#
# "permanent" (asterism-games 0.4.0, README "Permanent tables" there): the
# tables the host serves on the registered side with a certificate of its
# own, for the boards and the browsers with a pass; absent (an older host)
# or null (not set up) otherwise. Counts only (no names, nodes or tokens;
# the host's own node ID only). nil when no game host is set
# (ASTERISM_GAMES_STATUS_URL) or it does not answer.
require "net/http"
require "json"

module Relay
  module GamesStatus
    module_function

    def configured?(env = ENV) = Settings.games_status_url(env).present?

    def fetch(url = Settings.games_status_url)
      return nil if url.blank?
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |h| h.get(uri.request_uri) }
      res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError, SocketError
      nil
    end

    STATES = { "wait" => "in its lobby", "play" => "playing", "result" => "playing", "over" => "game over" }.freeze
    HOST_STATES = { "up" => "up", "starting" => "starting", "restarting" => "starting again",
                    "no certificate" => "waiting for its certificate (the .tar of its registry row)" }.freeze

    # The permanent tables (nil when the host has none): [what the host's
    # process is doing, one line per table].
    def permanent_text(status)
      perm = status.is_a?(Hash) ? status["permanent"] : nil
      return nil unless perm.is_a?(Hash)
      state = HOST_STATES.fetch(perm["state"].to_s, perm["state"].to_s)
      lines = tables_text(perm)
      lines = Array(perm["table_names"]).map { "#{_1}: -" } if lines.empty?
      [ state, lines ]
    end

    # One line per table of a room: "mahjong1: playing, 3 seated, 1 CPU, 5 at the table".
    def tables_text(room)
      tables = room.is_a?(Hash) ? room["tables"].to_h : {}
      return [] if tables.empty?
      tables.map do |name, t|
        parts = [ STATES.fetch(t["st"].to_s, t["st"].to_s), "#{t['humans'].to_i} seated", "#{t['cpus'].to_i} CPU",
                  "#{t['members'].to_i} at the table" ]
        parts << "#{t['away']} away" if t["away"].to_i.positive?
        "#{name}: #{parts.join(', ')}"
      end
    end
  end
end
