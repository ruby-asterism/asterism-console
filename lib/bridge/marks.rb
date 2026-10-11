# What the page draws on top of the graph (V2.2), derived from a graph in
# to_h form, so the same code serves the live graph (Graph#to_h) and
# recordings made before V2.2 (RecordingsController#graph):
#
#   - data "machine" on every Asterism node: "console" (this console),
#     "board" (a Family mruby board or its Linux / browser build) or "ruby"
#     (any other Ruby process, CRuby in practice). The network does not say
#     what a node runs on (an Asterism node is a liveliness token with its
#     name, nothing more), so this goes by the boards' naming: a board
#     calls itself by its mDNS name fmruby-<6 hex digits>, a browser build
#     by the ID its page made, wasm-<6 hex digits>, and the simulation falls
#     back to "linux" (a browser build without its page, "wasm"). A board
#     given another name in its node file shows as "ruby".
#   - the relay registry's names that are not here (kind "registered") in
#     one box, "reg_box" (label "Not connected (registry)"), instead of
#     each on its own.
#   - "expect" edges from such a name to the router the registry says it
#     connects to. The registry is the cloud router's list (its ACL): every
#     router and client in it that is enabled and has a valid certificate
#     ("in_acl") is let in by the cloud router and has nothing else to
#     connect to as far as the registry knows, so the expected router is the
#     cloud router (its name: cloud). The cloud router's own entry, and the
#     names the ACL leaves out (disabled, no valid certificate), have no
#     expected router: they only sit in the box. The edge goes to the cloud
#     router when it is here, to its entry in the box when it is registered
#     but not here, and nowhere otherwise.
#
# apply removes what it added before adding it again (idempotent).
module Bridge
  module Marks
    BOX = "reg_box".freeze
    BOX_LABEL = "Not connected (registry)".freeze
    # A board's node name: its mDNS name, the browser build's own ID
    # (wasm-<6 hex>, kept by its page since fmruby-core's B2), or the
    # fallback of the simulation (linux) and of the browser build (wasm).
    BOARD_NAME = /\A(fmruby-[0-9a-f]{6}|wasm-[0-9a-f]{6}|linux|wasm)\z/

    module_function

    def machine(node, self_node)
      return "console" if self_node
      BOARD_NAME.match?(node.to_s) ? "board" : "ruby"
    end

    # The router a registry entry connects to (by name), or nil when the
    # registry does not tell.
    def expected_router(peer, cloud)
      return nil unless cloud && peer.is_a?(Hash)
      return nil unless %w[client router].include?(peer["kind"]) && peer["in_acl"]
      return nil if peer["name"].to_s == cloud.to_s
      cloud.to_s
    end

    def apply(graph, cloud: nil)
      nodes = graph["nodes"].to_a.reject { _1["kind"] == BOX }.map do |n|
        case n["kind"]
        when "a_node"
          d = n["data"] || {}
          n.merge("data" => d.merge("machine" => machine(d["node"] || n["label"], d["self"])))
        when "registered"
          n.except("parent").merge("data" => (n["data"] || {}).except("expect"))
        else
          n
        end
      end
      edges = graph["edges"].to_a.reject { _1["kind"] == "expect" }
      absent = nodes.select { _1["kind"] == "registered" }
      unless absent.empty?
        nodes << { "id" => BOX, "kind" => BOX, "layer" => "infra", "label" => BOX_LABEL,
                   "data" => { "cloud" => cloud }.compact }
        routers = nodes.select { _1["kind"] == "router" }.to_h { [ _1.dig("data", "name").to_s, _1["id"] ] }
        absent.each do |n|
          n["parent"] = BOX
          name = expected_router(n.dig("data", "peer"), cloud)
          next unless name
          n["data"]["expect"] = name
          target = routers[name] || absent.find { _1["label"] == name }&.dig("id")
          next if target.nil? || target == n["id"]
          edges << { "id" => "expect:#{n['id']}->#{target}", "kind" => "expect", "source" => n["id"],
                     "target" => target, "layer" => "infra", "label" => nil }
        end
      end
      { "nodes" => nodes.sort_by { _1["id"] }, "edges" => edges.sort_by { _1["id"] } }.merge(
        graph.except("nodes", "edges")
      )
    end
  end
end
