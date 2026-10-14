# The streams of the pages. The graph page takes "console": graph diffs,
# the bridge's status, answers to requests, watched values and rates. The
# plot page takes "plots" (points, and what the bridge knows of each
# plotted target), the log page "logs" (log lines). The bridge broadcasts;
# nothing comes back over the socket (the pages write leases and requests
# through HTTP).
#
# The graph's diffs go on a stream of their own: with the rooms (0.2.1,
# docs/rooms.md) to the admins (ConsoleAdmin.rooms_visible?), without them to
# everyone else, so a user who is not an admin never receives a room.
class ConsoleChannel < ApplicationCable::Channel
  STREAM = "console"
  GRAPH = "console:graph"
  GRAPH_ROOMS = "console:graph:rooms"
  STREAMS = { nil => STREAM, "console" => STREAM, "plots" => "console:plots", "logs" => "console:logs" }.freeze

  def subscribed
    name = STREAMS[params[:stream]]
    return reject unless name
    stream_from name
    return unless name == STREAM
    stream_from(ConsoleAdmin.rooms_visible?(current_user, remote_ip) ? GRAPH_ROOMS : GRAPH)
  end

  def self.send_message(type, payload)
    ActionCable.server.broadcast(STREAM, payload.merge("type" => type))
  end

  # A new version of the graph: its diff with the rooms (to the admins) and
  # without them (to the others).
  def self.send_graph(version, diff, public_diff)
    ActionCable.server.broadcast(GRAPH_ROOMS, { "type" => "graph_diff", "version" => version, "diff" => diff })
    ActionCable.server.broadcast(GRAPH, { "type" => "graph_diff", "version" => version, "diff" => public_diff })
  end

  # To the plot page ("plots") or the log page ("logs").
  def self.send_to(stream, type, payload)
    ActionCable.server.broadcast(STREAMS.fetch(stream), payload.merge("type" => type))
  end
end
