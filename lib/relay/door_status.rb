# The door's connection counts (G2), for the rooms' admin page: what the
# door answers on its status port (bin/ws_door, WS_DOOR_STATUS_LISTEN):
#
#   {"rooms": {"<uid>": 3}, "slots": {"01": 3}, "total": 3, "limit": 48,
#    "per_room": 16, "since": "..."}
#
# nil when the door does not answer (the page says so).
require "net/http"
require "json"

module Relay
  module DoorStatus
    module_function

    def fetch(url = Settings.door_status_url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |h| h.get(uri.request_uri) }
      res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError, SocketError
      nil
    end
  end
end
