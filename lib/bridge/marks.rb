# What the page draws on top of the graph (V2.2), derived from a graph in
# to_h form, so the same code serves the live graph (Graph#to_h) and
# recordings made before V2.2 (RecordingsController#graph):
#
#   - data "machine" on every Asterism node: what Ruby runs it, by the
#     names of the profiles' kinds (V2.5): "family_mruby", "picoruby",
#     "cruby", "console", or another kind a profile told; and data
#     "machine_by", how that is known: "self" (this console), "profile" (the
#     node told it, asterism 0.5.0 and later) or "name". A node without a
#     profile (an older version) goes by the boards' naming, as in V2.2: a
#     board calls itself by its mDNS name fmruby-<6 hex digits>, a browser
#     build by the ID its page made, wasm-<6 hex digits>, and the simulation
#     falls back to "linux" (a browser build without its page, "wasm"); those
#     are "family_mruby", anything else "cruby" (any other Ruby process).
#     Before V2.5 the values were "board", "ruby" and "console".
#   - data "icon" on an Asterism node whose profile has an icon the store
#     has (icons:): the URL /icons/<icon_hash>.
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

    # [machine, how it is known] of an Asterism node's data.
    def machine(data, name = data["node"])
      return %w[console self] if data["self"]
      kind = data.dig("profile", "kind")
      return [ kind.to_s, "profile" ] if kind
      [ BOARD_NAME.match?(name.to_s) ? "family_mruby" : "cruby", "name" ]
    end

    def icon_url(data, icons)
      hash = data.dig("profile", "icon_hash")
      return nil unless hash && icons&.include?(hash)
      "/icons/#{hash}"
    end

    # The router a registry entry connects to (by name), or nil when the
    # registry does not tell.
    def expected_router(peer, cloud)
      return nil unless cloud && peer.is_a?(Hash)
      return nil unless %w[client router].include?(peer["kind"]) && peer["in_acl"]
      return nil if peer["name"].to_s == cloud.to_s
      cloud.to_s
    end

    def apply(graph, cloud: nil, icons: nil)
      nodes = graph["nodes"].to_a.reject { _1["kind"] == BOX }.map do |n|
        case n["kind"]
        when "a_node"
          d = (n["data"] || {}).except("icon")
          m, by = machine(d, d["node"] || n["label"])
          d = d.merge("machine" => m, "machine_by" => by)
          url = icon_url(d, icons)
          d["icon"] = url if url
          n.merge("data" => d)
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
