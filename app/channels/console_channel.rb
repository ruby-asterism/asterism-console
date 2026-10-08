# The one stream of the page: graph diffs, the bridge's status, answers to
# requests and watched values. The bridge broadcasts; nothing comes back
# over the socket (the page writes requests through HTTP).
class ConsoleChannel < ApplicationCable::Channel
  STREAM = "console"

  def subscribed
    stream_from STREAM
  end

  def self.send_message(type, payload)
    ActionCable.server.broadcast(STREAM, payload.merge("type" => type))
  end
end
