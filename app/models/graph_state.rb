# The graph as the bridge last saw it (one row). The page renders from it
# on load; later changes come over Action Cable as diffs with the version.
class GraphState < ApplicationRecord
  # The bridge counts as running while it has written within this time.
  ALIVE_FOR = 10.seconds

  def self.current
    first || create!(version: 0, snapshot: JSON.generate("nodes" => [], "edges" => []))
  end

  def graph
    snapshot.present? ? JSON.parse(snapshot) : { "nodes" => [], "edges" => [] }
  end

  def info
    bridge_info.present? ? JSON.parse(bridge_info) : {}
  end

  def bridge_alive?
    bridge_seen_at.present? && bridge_seen_at > ALIVE_FOR.ago
  end

  def as_payload
    { "version" => version, "graph" => graph, "bridge" => info.merge("alive" => bridge_alive?) }
  end
end
