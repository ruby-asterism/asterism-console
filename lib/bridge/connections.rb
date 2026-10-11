# The default drawing of the graph (V2.1): the nodes (Asterism nodes, ROS 2
# nodes, the console) joined to their router directly, instead of through a
# point for each Zenoh session. Derived from a graph in to_h form (its
# "session", "carries" and "peer_session" parts), so the same code serves
# the live graph (Graph#to_h) and recordings made before V2.1
# (RecordingsController#graph).
#
# Added:
#   - "attach" edges, node -> router, one per node and router: label the
#     roles of its sessions ("client" / "peer"), "sessions" their Zenoh IDs,
#     "shared" how many nodes the busiest of them carries (a ROS 2 process
#     with several nodes has one session for all of them).
#   - "others" nodes, one per router ("others:<router zid>"): the sessions
#     at that router that carry no node, with an "attach" edge to it.
#   - "peer_link" edges between the nodes of two sessions connected to each
#     other directly (peer to peer, "peer_session" edges): label "peer".
#   - data "connections" on every Asterism / ROS 2 node: its sessions, each
#     { "zid", "role", "address", "protocol", "links", "router", "router_label",
#       "cert_name", "self", "nodes" (ids of the nodes on that session) }.
#
# The sessions, "session" and "carries" edges stay: the page shows either
# them ("Sessions as points") or what is added here. apply is idempotent.
module Bridge
  module Connections
    DERIVED_EDGES = %w[attach peer_link].freeze
    HOLDERS = %w[a_node r_node].freeze

    module_function

    def apply(graph)
      nodes = graph["nodes"].to_a.reject { _1["kind"] == "others" }.to_h do |n|
        n = n.dup
        if HOLDERS.include?(n["kind"]) && n["data"].is_a?(Hash)
          n["data"] = n["data"].except("connections")
        end
        [ n["id"], n ]
      end
      edges = graph["edges"].to_a.reject { DERIVED_EDGES.include?(_1["kind"]) }.to_h { [ _1["id"], _1 ] }
      router_of = {}
      carried = Hash.new { |h, k| h[k] = [] }
      edges.each_value do |e|
        case e["kind"]
        when "session" then router_of[e["target"]] = e["source"]
        when "carries" then carried[e["source"]] << e["target"] if nodes[e["target"]]
        end
      end
      # The console's sessions that carry no token of their own (the bridge's
      # reader) belong to the console all the same.
      me = nodes.values.find { _1["kind"] == "a_node" && _1.dig("data", "self") }
      sessions = nodes.values.select { _1["kind"] == "session" }.sort_by { _1["id"] }
      sessions.each do |s|
        carried[s["id"]] << me["id"] if me && carried[s["id"]].empty? && s.dig("data", "self")
      end
      HOLDERS.each { |k| nodes.each_value { _1["data"]["connections"] = [] if _1["kind"] == k && _1["data"].is_a?(Hash) } }

      out = {}
      add_edge = lambda do |id, kind, source, target, label|
        layer = [ nodes[source]["layer"], nodes[target]["layer"] ].uniq
        out[id] ||= { "id" => id, "kind" => kind, "source" => source, "target" => target,
                      "layer" => layer.size == 1 ? layer[0] : "cross", "label" => label }
      end
      others = Hash.new { |h, k| h[k] = [] }
      holder = {} # session id => the ids its peer links start from
      sessions.each do |s|
        d = s["data"] || {}
        rid = router_of[s["id"]]
        held = carried[s["id"]].uniq.sort
        entry = { "zid" => d["zid"], "role" => d["whatami"], "address" => d["address"], "protocol" => d["protocol"],
                  "links" => d["links"], "router" => rid, "router_label" => rid && nodes[rid]["label"],
                  "cert_name" => d["cert_name"], "self" => d["self"] ? true : false, "nodes" => held }.compact
        if held.empty?
          next unless rid
          others[rid] << entry
          holder[s["id"]] = [ "others:#{rid.delete_prefix('router:')}" ]
          next
        end
        holder[s["id"]] = held
        held.each do |nid|
          nodes[nid]["data"]["connections"] << entry
          next unless rid
          e = add_edge.("attach:#{nid}->#{rid}", "attach", nid, rid, nil)
          e["sessions"] = ((e["sessions"] || []) + [ d["zid"] ]).uniq
          e["roles"] = ((e["roles"] || []) + [ d["whatami"] ]).compact.uniq.sort
          e["label"] = e["roles"].join(" / ")
          e["shared"] = [ e["shared"] || 0, held.size ].max
        end
      end
      others.each do |rid, list|
        id = "others:#{rid.delete_prefix('router:')}"
        nodes[id] = { "id" => id, "kind" => "others", "layer" => "infra",
                      "label" => "#{list.size} other connection#{list.size == 1 ? '' : 's'}",
                      "data" => { "router" => rid, "sessions" => list } }
        add_edge.("attach:#{id}->#{rid}", "attach", id, rid, nil)["sessions"] = list.map { _1["zid"] }
      end
      edges.each_value do |e|
        next unless e["kind"] == "peer_session"
        Array(holder[e["source"]]).product(Array(holder[e["target"]])).each do |a, b|
          next if a == b || !nodes[a] || !nodes[b]
          a, b = [ a, b ].sort
          add_edge.("peer_link:#{a}->#{b}", "peer_link", a, b, "peer")
        end
      end
      all = edges.merge(out)
      { "nodes" => nodes.keys.sort.map { nodes[_1] }, "edges" => all.keys.sort.map { all[_1] } }.merge(
        graph.except("nodes", "edges")
      )
    end
  end
end
