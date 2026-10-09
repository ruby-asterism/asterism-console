# Which registry names the graph shows now: Asterism node IDs and router
# names (the certificate name = node ID convention).
module Relay
  module Presence
    module_function

    def seen(graph)
      graph["nodes"].to_a.filter_map do |n|
        case n["kind"]
        when "a_node" then n.dig("data", "node")
        when "router" then n.dig("data", "name")
        end
      end.to_set
    end
  end
end
