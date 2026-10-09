# The network as a graph of typed nodes and edges, built from what the
# bridge collects. Pure Ruby (no Zenoh): the bridge feeds it, the tests
# feed it by hand.
#
# Inputs:
#   admin:    { router_zid => { "router" => Hash (the JSON of @/<zid>/router),
#                               "linkstate" => { name => dot text },
#                               "tokens" => { token key => { "clients" => [...],
#                                                            "peers" => [...],
#                                                            "routers" => [...] } } } }
#   asterism: token keys alive under asterism/** (with the "asterism/" prefix)
#   ros:      token keys alive under @ros2_lv/**
#   self_node: the bridge's own Asterism node ID (marked, not hidden)
#   self_zids: the bridge's own Zenoh session IDs (marked)
#   own_links: the bridge's own links ({ router zid => { "protocol" =>,
#              "cert_name" => } }): the certificate name of the router the
#              bridge is connected to (the admin space does not tell it)
#   self_cert: the common name of the bridge's own certificate (its sessions)
#   registry: the relay registry (RelayPeer.registry: "name", "kind",
#             "enabled", "in_acl", ...), or nil for none. Asterism nodes
#             (by ID) and routers (by metadata/name) are matched to it by
#             name, the certificate name = node ID convention, and marked
#             (data "registry"): "registered" (in the registry, here),
#             "disabled" (here, but disabled in the registry), "unregistered"
#             (here, not in the registry); a registered name not seen gets a
#             node of its own ("absent", kind "registered").
#
# Output (to_h): { "nodes" => [node, ...], "edges" => [edge, ...] }, each a
# Hash with "id", "kind", "layer", "label" and "data" (nodes) or
# "source" / "target" (edges). Sorted by id, so equal networks give equal
# graphs and the diff is stable.
module Bridge
  class Graph
    LAYERS = {
      "router" => "infra", "session" => "infra", "registered" => "infra",
      "a_node" => "asterism", "a_app" => "asterism", "a_object" => "asterism",
      "r_node" => "ros", "r_topic" => "ros", "r_service" => "ros"
    }.freeze

    ROS_ENTITIES = {
      "NN" => :node, "MP" => :publisher, "MS" => :subscriber,
      "SS" => :server, "SC" => :client
    }.freeze

    attr_reader :nodes, :edges

    def self.build(admin: {}, asterism: [], ros: [], self_node: nil, self_zids: [], own_links: {}, self_cert: nil,
                   registry: nil)
      g = new
      g.add_admin(admin, self_zids.map { norm_zid(_1) })
      g.add_own_links(own_links)
      g.add_asterism(asterism, self_node)
      g.add_ros(ros)
      g.link_tokens(admin)
      g.add_self_cert(self_cert)
      g.add_registry(registry) if registry
      g
    end

    # Zenoh prints IDs as lowercase hex; compare them without leading zeros.
    def self.norm_zid(zid)
      z = zid.to_s.downcase.sub(/\A0+/, "")
      z.empty? ? "0" : z
    end

    def self.short(zid)
      zid.to_s[0, 8]
    end

    # "tls/192.0.2.2:7448" -> "tls"
    def self.protocol(locator)
      locator.to_s[%r{\A([a-z0-9-]+)/}, 1]
    end

    # "%" stands for "/" inside rmw_zenoh's tokens.
    def self.ros_name(part)
      part.to_s.tr("%", "/")
    end

    # std_msgs::msg::dds_::String_ -> std_msgs/msg/String
    def self.ros_type(dds)
      parts = dds.to_s.split("::")
      return dds.to_s unless parts.size == 4 && parts[2] == "dds_"
      "#{parts[0]}/#{parts[1]}/#{parts[3].delete_suffix('_')}"
    end

    # One rmw_zenoh liveliness token, or nil when it is not one:
    # @ros2_lv/<domain>/<zid>/<nid>/<eid>/<kind>/<enclave>/<ns>/<node>
    #   [/<name>/<type>/<type hash>/<qos>]
    def self.parse_ros_token(key)
      parts = key.to_s.split("/")
      return nil unless parts[0] == "@ros2_lv" && parts.size >= 9
      kind = ROS_ENTITIES[parts[5]]
      return nil unless kind
      t = {
        kind: kind, domain: parts[1], zid: parts[2], nid: parts[3], eid: parts[4],
        enclave: ros_name(parts[6]), namespace: ros_name(parts[7]), node: parts[8]
      }
      if kind != :node
        return nil unless parts.size >= 12
        t[:name] = ros_name(parts[9])
        t[:type] = ros_type(parts[10])
        t[:type_hash] = parts[11]
        t[:qos] = parts[12]
      end
      t
    end

    # Router-to-router edges of a linkstate graph (Graphviz dot text):
    #   0 [ label = "zid" ]  ...  0 -> 1 [ ... ]
    def self.parse_linkstate(dot)
      labels = {}
      pairs = []
      dot.to_s.each_line do |line|
        if (m = line.match(/^\s*(\d+)\s*\[\s*label\s*=\s*"([0-9a-fA-F]+)"/))
          labels[m[1]] = m[2]
        elsif (m = line.match(/^\s*(\d+)\s*-[->]\s*(\d+)/))
          pairs << [ m[1], m[2] ]
        end
      end
      pairs.filter_map { |a, b| [ labels[a], labels[b] ] if labels[a] && labels[b] }
    end

    def initialize
      @nodes = {}
      @edges = {}
      @session_of = {} # normalized zid => node id (router or session)
    end

    def node(id, kind, label, data = {})
      n = (@nodes[id] ||= { "id" => id, "kind" => kind, "layer" => LAYERS.fetch(kind), "label" => label, "data" => {} })
      n["data"].merge!(data.transform_keys(&:to_s))
      n
    end

    def edge(source, target, kind, label = nil)
      return unless @nodes[source] && @nodes[target]
      id = "#{kind}:#{source}->#{target}"
      layer = [ @nodes[source]["layer"], @nodes[target]["layer"] ].uniq
      @edges[id] ||= { "id" => id, "kind" => kind, "source" => source, "target" => target,
                       "layer" => layer.size == 1 ? layer[0] : "cross", "label" => label }
    end

    # ---------------------------------------------------------------- routers

    def add_admin(admin, self_zids)
      admin.each do |rzid, info|
        router_node(rzid, info["router"] || {})
      end
      admin.each do |rzid, info|
        rid = "router:#{self.class.norm_zid(rzid)}"
        Array((info["router"] || {})["sessions"]).each do |s|
          add_session(rid, s, self_zids)
        end
        (info["linkstate"] || {}).each_value do |dot|
          self.class.parse_linkstate(dot).each do |a, b|
            router_edge(router_node(a)["id"], router_node(b)["id"])
          end
        end
      end
    end

    # One edge per pair of routers, whichever side told it (both do).
    def router_edge(ida, idb, protocol = nil)
      return if ida == idb
      a, b = [ ida, idb ].sort
      e = edge(a, b, "router_link")
      e["label"] ||= protocol if e && protocol
      e
    end

    def add_own_links(own)
      own.each do |rzid, link|
        n = @nodes["router:#{self.class.norm_zid(rzid)}"]
        next unless n
        n["data"]["bridge_link"] = link.slice("protocol", "cert_name").compact
        n["data"]["cert_name"] ||= link["cert_name"] if link["cert_name"]
      end
    end

    def router_node(zid, json = nil)
      nz = self.class.norm_zid(zid)
      id = "router:#{nz}"
      data = { "zid" => zid.to_s }
      if json && !json.empty?
        name = json["metadata"].is_a?(Hash) ? json["metadata"]["name"] : nil
        data["name"] = name.to_s if name
        data["version"] = json["version"].to_s.split(" ").first
        data["locators"] = Array(json["locators"])
        data["plugins"] = (json["plugins"] || {}).keys.sort
        data["sessions"] = Array(json["sessions"]).size
        data["seen"] = true
      end
      @session_of[nz] = id
      n = node(id, "router", "router #{self.class.short(zid)}", data)
      n["label"] = "router #{data['name']}" if data["name"] && !data["name"].empty?
      n
    end

    def add_session(rid, s, self_zids)
      zid = s["peer"].to_s
      nz = self.class.norm_zid(zid)
      links = Array(s["links"]).map { |l| { "src" => l["src"], "dst" => l["dst"] } }
      protocols = links.filter_map { self.class.protocol(_1["dst"]) }.uniq
      if s["whatami"] == "router"
        other = router_node(zid)
        router_edge(rid, other["id"], protocols.join(","))
        # This router's own view of the link (each side of a pair lists it).
        rl = (@nodes[rid]["data"]["router_links"] ||= [])
        rl << { "peer" => zid, "protocol" => protocols.join(","), "links" => links } unless rl.any? { _1["peer"] == zid }
        return
      end
      id = "session:#{nz}"
      addr = links.first && links.first["dst"]
      node(id, "session", "#{s['whatami']} #{self.class.short(zid)}",
           "zid" => zid, "whatami" => s["whatami"], "links" => links, "address" => addr,
           "protocol" => protocols.join(","), "region" => s["region"], "self" => self_zids.include?(nz))
      @session_of[nz] = id
      edge(rid, id, "session")
    end

    # --------------------------------------------------------------- asterism

    def add_asterism(keys, self_node)
      keys.each do |key|
        parts = key.to_s.sub(%r{\Aasterism/}, "").split("/")
        next if parts.empty? || parts.any?(&:empty?)
        case parts.size
        when 1
          a_node(parts[0], self_node)
        when 3
          nid, app, obj = parts
          a_node(nid, self_node)
          aid = "a_app:#{nid}/#{app}"
          node(aid, "a_app", app, "node" => nid, "app" => app)
          oid = "a_object:#{nid}/#{app}/#{obj}"
          node(oid, "a_object", obj, "path" => "#{nid}/#{app}/#{obj}", "node" => nid, "app" => app)
          edge("a_node:#{nid}", aid, "has_app")
          edge(aid, oid, "exposes")
        end
      end
    end

    def a_node(nid, self_node)
      node("a_node:#{nid}", "a_node", nid, "node" => nid, "self" => nid == self_node)
    end

    # -------------------------------------------------------------------- ros

    def add_ros(keys)
      keys.each do |key|
        t = self.class.parse_ros_token(key)
        next unless t
        nid = ros_node(t)
        case t[:kind]
        when :publisher, :subscriber
          tid = "r_topic:#{t[:domain]}#{t[:name]}"
          node(tid, "r_topic", t[:name], "name" => t[:name], "type" => t[:type],
               "type_hash" => t[:type_hash], "domain" => t[:domain])
          if t[:kind] == :publisher
            edge(nid, tid, "publishes")
          else
            edge(tid, nid, "subscribes")
          end
        when :server, :client
          sid = "r_service:#{t[:domain]}#{t[:name]}"
          node(sid, "r_service", t[:name], "name" => t[:name], "type" => t[:type], "domain" => t[:domain])
          if t[:kind] == :server
            edge(sid, nid, "serves")
          else
            edge(nid, sid, "calls")
          end
        end
      end
    end

    def ros_node(t)
      full = t[:namespace] == "/" ? "/#{t[:node]}" : "#{t[:namespace]}/#{t[:node]}"
      id = "r_node:#{self.class.norm_zid(t[:zid])}/#{t[:nid]}"
      node(id, "r_node", full, "name" => full, "zid" => t[:zid], "domain" => t[:domain],
           "enclave" => t[:enclave])
      id
    end

    # ------------------------------------------------------- crossing layers

    # Which session carries what: the router's token table names the session
    # behind each Asterism token; ROS tokens carry their session's ID.
    def link_tokens(admin)
      admin.each do |rzid, info|
        own = self.class.norm_zid(rzid)
        (info["tokens"] || {}).each do |key, who|
          m = key.to_s.match(%r{\Aasterism/([^/]+)})
          next unless m
          nid = "a_node:#{m[1]}"
          next unless @nodes[nid]
          (Array(who["clients"]) + Array(who["peers"])).each do |z|
            nz = self.class.norm_zid(z)
            next if nz == own
            sid = @session_of[nz]
            next unless sid
            edge(sid, nid, "carries")
            @nodes[sid]["data"]["self"] = true if @nodes[nid]["data"]["self"]
          end
        end
      end
      @nodes.each_value do |n|
        next unless n["kind"] == "r_node"
        sid = @session_of[self.class.norm_zid(n["data"]["zid"])]
        edge(sid, n["id"], "carries") if sid
      end
    end

    def add_self_cert(name)
      return unless name
      @nodes.each_value do |n|
        n["data"]["cert_name"] = name if n["kind"] == "session" && n["data"]["self"]
      end
    end

    # --------------------------------------------------------------- registry

    def add_registry(registry)
      by_name = registry.to_h { [ _1["name"].to_s, _1 ] }
      seen = {}
      @nodes.values.each do |n|
        name = case n["kind"]
        when "a_node" then n["data"]["node"]
        when "router" then n["data"]["name"]
        end
        next if name.nil? || name.empty?
        peer = by_name[name]
        if peer
          seen[name] = true
          n["data"]["registry"] = peer["enabled"] ? "registered" : "disabled"
          n["data"]["peer"] = peer.slice("name", "kind", "enabled", "in_acl", "expires").compact
        else
          n["data"]["registry"] = "unregistered"
        end
        n["data"]["via"] = via_router(n) if n["kind"] == "a_node"
      end
      by_name.each do |name, peer|
        next if seen[name]
        node("reg:#{name}", "registered", name, "registry" => "absent",
             "peer" => peer.slice("name", "kind", "enabled", "in_acl", "expires", "description").compact)
      end
    end

    # The router an Asterism node comes through (its session's router).
    def via_router(n)
      sid = @edges.values.find { _1["kind"] == "carries" && _1["target"] == n["id"] }&.dig("source")
      return nil unless sid
      rid = @edges.values.find { _1["kind"] == "session" && _1["target"] == sid }&.dig("source")
      r = rid && @nodes[rid]
      r && (r["data"]["name"] || r["label"])
    end

    # ---------------------------------------------------------------- output

    def to_h
      { "nodes" => @nodes.keys.sort.map { @nodes[_1] }, "edges" => @edges.keys.sort.map { @edges[_1] } }
    end

    # What changed from old to new (both to_h): added / removed / changed.
    def self.diff(old, new)
      out = {}
      %w[nodes edges].each do |part|
        a = (old || {})[part].to_a.to_h { [ _1["id"], _1 ] }
        b = (new || {})[part].to_a.to_h { [ _1["id"], _1 ] }
        out["add_#{part}"] = b.reject { |id, _| a.key?(id) }.values
        out["remove_#{part}"] = a.keys.reject { b.key?(_1) }
        out["change_#{part}"] = b.select { |id, v| a.key?(id) && a[id] != v }.values
      end
      out
    end

    def self.empty_diff?(d)
      d.values.all?(&:empty?)
    end
  end
end
