# The streams of the pages. The graph page takes "console": graph diffs,
# the bridge's status, answers to requests, watched values and rates. The
# plot page takes "plots" (points, and what the bridge knows of each
# plotted target), the log page "logs" (log lines). The bridge broadcasts;
# nothing comes back over the socket (the pages write leases and requests
# through HTTP).
class ConsoleChannel < ApplicationCable::Channel
  STREAM = "console"
  STREAMS = { nil => STREAM, "console" => STREAM, "plots" => "console:plots", "logs" => "console:logs" }.freeze

  def subscribed
    name = STREAMS[params[:stream]]
    return reject unless name
    stream_from name
  end

  def self.send_message(type, payload)
    ActionCable.server.broadcast(STREAM, payload.merge("type" => type))
  end

  # To the plot page ("plots") or the log page ("logs").
  def self.send_to(stream, type, payload)
    ActionCable.server.broadcast(STREAMS.fetch(stream), payload.merge("type" => type))
  end
end
