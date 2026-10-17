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
#   asterism: token keys alive under asterism/** (with the "asterism/" prefix):
#             asterism/<node>/<app> (an application) and
#             asterism/<node>/<app>/<object> (an exposed object), protocol 1
#   ros:      token keys alive under @ros2_lv/**
#   rooms:    token keys alive under room/*/asterism/** (0.2.1, docs/rooms.md):
#             room/<slot>/asterism/<node>/<app>[/<object>]
#   room_info: the open rooms (Room.for_graph: "slot", "name", "uid",
#             "expires_at", "app"), for the rooms' frames
#   room_hosts: the node IDs of the game hosts that join the rooms with their
#             own certificates (Relay::Settings.room_hosts, "games"): such a
#             node in a room's frame gets data "room_host" (0.3.3)
#   self_node: the bridge's own Asterism node ID (marked, not hidden)
#   self_zids: the bridge's own Zenoh session IDs (marked)
#   own_links: the bridge's own links ({ router zid => { "protocol" =>,
#              "cert_name" =>, "local" => } }): the certificate name of the
#              router the bridge is connected to (the admin space does not
#              tell it) and the bridge's own end of the link (its locator,
#              for Bridge::Gateways)
#   self_cert: the common name of the bridge's own certificate (its sessions)
#   registry: the relay registry (RelayPeer.registry: "name", "kind",
#             "enabled", "in_acl", ...), or nil for none. Asterism nodes
#             (by ID) and routers (by metadata/name) are matched to it by
#             name, the certificate name = node ID convention, and marked
#             (data "registry"): "registered" (in the registry, here),
#             "disabled" (here, but disabled in the registry), "unregistered"
#             (here, not in the registry); a registered name not seen gets a
#             node of its own ("absent", kind "registered").
#   peer_links: [zid, zid] pairs of sessions connected to each other without
#             a router (the bridge's own: Session#peer_zids)
#   cloud:    the cloud router's name (Relay::Settings.cloud_name), for the
#             routers the registry's names are expected at (Bridge::Marks)
#   names:    the machine names (MachineName.for_graph: "id", "name",
#             "members"), for the groups of ROS 2 nodes (Bridge::Groups)
#   gateways: IP addresses known to be a gateway (Gateways.configured:
#             ASTERISM_GATEWAY_IPS), besides the ones the graph shows
#             (Bridge::Gateways): ROS 2 nodes from them are not folded
#
# Output (to_h): { "nodes" => [node, ...], "edges" => [edge, ...] }, each a
# Hash with "id", "kind", "layer", "label" and "data" (nodes) or
# "source" / "target" (edges). Sorted by id, so equal networks give equal
# graphs and the diff is stable.
#
# The shape (V2, like rqt_graph's nodes-only view):
#   - Asterism apps and objects nest in their node: they carry "parent"
#     (the node's / app's id; compound nodes in the page), no edges.
#   - ROS 2 services are not nodes: each ROS 2 node lists the services it
#     serves and calls (data "services" / "clients", with "parameter" for
#     the parameter services every rclcpp node has).
#   - ROS 2 topics are edges from the publishing node to the subscribing
#     node ("topic_link", one per pair, its "topics" listed). Topics stay as
#     nodes with "publishes" / "subscribes" edges too, for the page's
#     topics-as-nodes view; data "matched" says whether a topic has a
#     publisher and a subscriber on different nodes. A node's topics with
#     no counterpart are its data "unmatched".
#   - The default drawing (V2.1, Bridge::Connections): nodes joined to their
#     router by "attach" edges, the sessions that carry no node in one
#     "others" node per router, "peer_link" edges between nodes of sessions
#     connected directly, and each node's sessions as its data
#     "connections". Sessions stay, for the page's "Sessions as points".
#   - The groups (V2.3, Bridge::Groups): the ROS 2 nodes that come from the
#     same IP address (two or more) folded into one "r_group" node, with
#     folded copies of their edges; a group takes the machine name whose
#     node names match its own. The ROS 2 nodes that come from a gateway's
#     address (V2.4, Bridge::Gateways: a NAT, such as Docker's published
#     ports) are not folded: the machine behind it is not known.
#   - The marks (V2.2, Bridge::Marks): what each Asterism node runs on (data
#     "machine"; V2.5: from its profile when it has one), the icon's URL, the
#     registered names not here in one box ("reg_box") with "expect" edges to
#     the router the registry says they connect to.
#   - The profiles (V2.5, Bridge::Profiles): data "profile" on an Asterism
#     node that told its profile (kind, host, name, icon_hash).
#   - Through a router (V2.6): a node no readable router carries, whose
#     token a readable router's table lists under "routers" (a router whose
#     admin space the console cannot read), gets a "via_router" edge, node
#     -> that router, label "via". Not drawn when a "carries" edge exists.
#   - The rooms (0.2.1, docs/rooms.md): one "room" node per open room and per
#     slot with tokens ("room:<slot>", data "slot", "name", "expires_at", ...),
#     holding the room's Asterism nodes (ids "a_node:room/<slot>/<node>", so a
#     room's wasm-abc123 is not the registered side's), their apps and
#     objects; everything of a room has data "room" (its slot). Their
#     sessions carry them like any other node's. Graph.without_rooms takes
#     all of it out again (for the users who are not admins).
#   - A room's game host (0.3.3): a node in a room's frame whose ID is one of
#     room_hosts has data "room_host" true; the page labels it "<ID> (room
#     <slot>)" ("games (room 05)"), apart from the host's node of the same ID
#     outside the rooms (its permanent tables, labelled by its profile). The
#     console cannot read the profiles in a room, so the mark is the
#     console's own.
module Bridge
  class Graph
    LAYERS = {
      "router" => "infra", "session" => "infra", "registered" => "infra",
      "a_node" => "asterism", "a_app" => "asterism", "a_object" => "asterism",
      "r_node" => "ros", "r_topic" => "ros", "others" => "infra", "room" => "rooms"
    }.freeze

    # An Asterism token of a room: room/<slot>/asterism/<rest>.
    ROOM_TOKEN = %r{\Aroom/([^/]+)/asterism/(.+)\z}

    # The services every rclcpp node serves for its parameters (and its
    # type description): /<node>/<one of these>.
    PARAMETER_SERVICES = %w[
      describe_parameters get_parameters set_parameters list_parameters get_parameter_types
      set_parameters_atomically get_type_description
    ].freeze

    ROS_ENTITIES = {
      "NN" => :node, "MP" => :publisher, "MS" => :subscriber,
      "SS" => :server, "SC" => :client
    }.freeze

    attr_reader :nodes, :edges
    # The cloud router's name (Relay::Settings.cloud_name): the router the
    # registry's entries are expected at (Bridge::Marks).
    attr_accessor :cloud
    # The machine names (Bridge::Groups).
    attr_accessor :names
    # The configured gateway addresses (Bridge::Gateways).
    attr_accessor :gateways
    # The icon hashes the store has (Bridge::Marks gives those nodes "icon").
    attr_accessor :icons

    def self.build(admin: {}, asterism: [], ros: [], self_node: nil, self_zids: [], own_links: {}, self_cert: nil,
                   registry: nil, peer_links: [], cloud: nil, names: [], gateways: [], profiles: {}, icons: nil,
                   rooms: [], room_info: [], room_hosts: [], statuses: {})
      g = new
      g.cloud = cloud
      g.icons = icons
      g.names = names
      g.gateways = gateways
      g.add_admin(admin, self_zids.map { norm_zid(_1) })
      g.add_own_links(own_links)
      g.add_peer_links(peer_links, self_zids.map { norm_zid(_1) })
      g.add_asterism(asterism, self_node)
      g.add_profiles(profiles)
      g.add_statuses(statuses)
      g.add_rooms(rooms, room_info, room_hosts)
      g.add_ros(ros)
      g.finish_ros
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

    def node(id, kind, label, data = {}, parent = nil)
      n = (@nodes[id] ||= { "id" => id, "kind" => kind, "layer" => LAYERS.fetch(kind), "label" => label, "data" => {} })
      n["parent"] = parent if parent
      n["data"].merge!(data.transform_keys(&:to_s))
      n
    end

    # A parameter service of a node (/<node>/describe_parameters, ...).
    def self.parameter_service?(name)
      PARAMETER_SERVICES.include?(name.to_s.split("/").last)
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
        n["data"]["bridge_link"] = link.slice("protocol", "cert_name", "local").compact
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

    # Sessions connected to each other directly, not through a router
    # ([zid, zid] pairs; the bridge knows its own: Session#peer_zids). The
    # routers' admin space does not show these links. A session no router
    # has is added here (whatami "peer", no router).
    def add_peer_links(pairs, self_zids)
      pairs.each do |a, b|
        ids = [ a, b ].map do |z|
          nz = self.class.norm_zid(z)
          next nil if @session_of[nz]&.start_with?("router:")
          @session_of[nz] ||= node("session:#{nz}", "session", "peer #{self.class.short(z)}",
                                   "zid" => z.to_s, "whatami" => "peer", "links" => [],
                                   "self" => self_zids.include?(nz))["id"]
        end
        next if ids.include?(nil) || ids.uniq.size < 2
        x, y = ids.sort
        edge(x, y, "peer_session", "peer")
      end
    end

    # --------------------------------------------------------------- asterism

    def add_asterism(keys, self_node)
      keys.each do |key|
        parts = key.to_s.sub(%r{\Aasterism/}, "").split("/")
        next if parts.empty? || parts.any?(&:empty?)
        case parts.size
        when 2 # an application's token (protocol 1): the app is up, maybe with no object
          nid, app = parts
          a_node(nid, self_node)
          node("a_app:#{nid}/#{app}", "a_app", app, { "node" => nid, "app" => app }, "a_node:#{nid}")
        when 3
          nid, app, obj = parts
          a_node(nid, self_node)
          aid = "a_app:#{nid}/#{app}"
          node(aid, "a_app", app, { "node" => nid, "app" => app }, "a_node:#{nid}")
          oid = "a_object:#{nid}/#{app}/#{obj}"
          node(oid, "a_object", obj, { "path" => "#{nid}/#{app}/#{obj}", "node" => nid, "app" => app }, aid)
        end
      end
    end

    # The rooms (0.2.1): a frame per open room (and per slot with tokens but
    # no open room: what is left of one that ended), holding its nodes.
    def add_rooms(keys, info, hosts = [])
      by_slot = Array(info).to_h { [ _1["slot"].to_s, _1 ] }
      by_slot.each { |slot, room| room_frame(slot, room) }
      Array(keys).each do |key|
        m = ROOM_TOKEN.match(key.to_s) or next
        slot = m[1]
        parts = m[2].split("/")
        next if parts.size < 2 || parts.size > 3 || parts.any?(&:empty?)
        nid, app, obj = parts
        frame = room_frame(slot, by_slot[slot])
        base = "room/#{slot}/#{nid}"
        data = { "node" => nid, "room" => slot }
        data["room_host"] = true if hosts.include?(nid)
        node("a_node:#{base}", "a_node", nid, data, frame)
        aid = "a_app:#{base}/#{app}"
        node(aid, "a_app", app, { "node" => nid, "app" => app, "room" => slot }, "a_node:#{base}")
        next unless obj
        node("a_object:#{base}/#{app}/#{obj}", "a_object", obj,
             { "path" => "#{base}/#{app}/#{obj}", "node" => nid, "app" => app, "room" => slot }, aid)
      end
    end

    def room_frame(slot, room)
      data = { "slot" => slot, "room" => slot, "open" => !room.nil? }
      data.merge!(room.slice("name", "uid", "expires_at", "app").compact) if room
      node("room:#{slot}", "room", room ? room["name"].to_s : "room #{slot}", data)["id"]
    end

    # A graph (to_h form) without the rooms: their frames, nodes, apps and
    # objects, the edges to them, and the sessions that carry nothing else
    # (with their edges). For the users who are not admins.
    def self.without_rooms(graph)
      gone = graph["nodes"].to_a.select { _1["kind"] == "room" || _1.dig("data", "room") }.map { _1["id"] }.to_set
      return graph if gone.empty?
      carries = graph["edges"].to_a.select { _1["kind"] == "carries" }.group_by { _1["source"] }
      carries.each do |sid, list|
        gone << sid if list.all? { gone.include?(_1["target"]) }
      end
      nodes = graph["nodes"].to_a.reject { gone.include?(_1["id"]) }
      edges = graph["edges"].to_a.reject { gone.include?(_1["source"]) || gone.include?(_1["target"]) }
      graph.merge("nodes" => nodes, "edges" => edges)
    end

    # The profiles the nodes told (V2.5): data "profile" (kind, host, name,
    # icon_hash) on the Asterism nodes that are here.
    def add_profiles(profiles)
      (profiles || {}).each do |nid, summary|
        n = @nodes["a_node:#{nid}"]
        n["data"]["profile"] = summary if n && summary
      end
    end

    # The applications' statuses (0.3.4, Bridge::Statuses): data "status"
    # on the Asterism apps that are here (shown in the details; nothing
    # drawn changes).
    def add_statuses(statuses)
      (statuses || {}).each do |app, st|
        n = @nodes["a_app:#{app}"]
        n["data"]["status"] = st if n && st
      end
    end

    def a_node(nid, self_node)
      node("a_node:#{nid}", "a_node", nid, "node" => nid, "self" => nid == self_node)
    end

    # -------------------------------------------------------------------- ros

    def add_ros(keys)
      @ros_topics = {}   # topic id => { "publishers" => Set, "subscribers" => Set }
      @ros_services = {} # node id => { "services" => {name => entry}, "clients" => {...} }
      keys.each do |key|
        t = self.class.parse_ros_token(key)
        next unless t
        nid = ros_node(t)
        case t[:kind]
        when :publisher, :subscriber
          tid = "r_topic:#{t[:domain]}#{t[:name]}"
          node(tid, "r_topic", t[:name], "name" => t[:name], "type" => t[:type],
               "type_hash" => t[:type_hash], "domain" => t[:domain])
          ends = (@ros_topics[tid] ||= { "publishers" => {}, "subscribers" => {} })
          if t[:kind] == :publisher
            ends["publishers"][nid] = true
            edge(nid, tid, "publishes")
          else
            ends["subscribers"][nid] = true
            edge(tid, nid, "subscribes")
          end
        when :server, :client
          role = t[:kind] == :server ? "services" : "clients"
          entry = { "name" => t[:name], "type" => t[:type], "domain" => t[:domain],
                    "parameter" => self.class.parameter_service?(t[:name]) }
          ((@ros_services[nid] ||= { "services" => {}, "clients" => {} })[role])[t[:name]] = entry
        end
      end
    end

    # After all the tokens: the services as node attributes, topic edges
    # between the nodes, and the topics that have no counterpart.
    def finish_ros
      (@ros_services || {}).each do |nid, roles|
        roles.each do |role, by_name|
          @nodes[nid]["data"][role] = by_name.keys.sort.map { by_name[_1] }
        end
      end
      unmatched = Hash.new { |h, k| h[k] = [] }
      links = Hash.new { |h, k| h[k] = [] }
      (@ros_topics || {}).sort.each do |tid, ends|
        pubs = ends["publishers"].keys.sort
        subs = ends["subscribers"].keys.sort
        topic = @nodes[tid]
        topic["data"]["publishers"] = pubs
        topic["data"]["subscribers"] = subs
        pairs = pubs.product(subs).reject { |a, b| a == b }
        topic["data"]["matched"] = pairs.any?
        pairs.each { |a, b| links[[ a, b ]] << tid }
        brief = topic["data"].slice("name", "type").merge("topic" => tid)
        pubs.each { |p| unmatched[p] << brief.merge("role" => "publishes") if (subs - [ p ]).empty? }
        subs.each { |q| unmatched[q] << brief.merge("role" => "subscribes") if (pubs - [ q ]).empty? }
      end
      links.each do |(a, b), tids|
        e = edge(a, b, "topic_link")
        e["topics"] = tids.sort
        e["label"] = tids.sort.map { @nodes[_1]["label"] }.join("\n")
      end
      unmatched.each { |nid, list| @nodes[nid]["data"]["unmatched"] = list }
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
      via = Hash.new { |h, k| h[k] = {} } # node id => { router id => true }
      admin.each do |rzid, info|
        own = self.class.norm_zid(rzid)
        (info["tokens"] || {}).each do |key, who|
          note_via(via, key, who, own)
          nid = asterism_node_id(key)
          next unless nid && @nodes[nid]
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
      link_via(via, admin)
    end

    # The Asterism node (its id) an Asterism token names, in a room or not.
    def asterism_node_id(key)
      if (m = key.to_s.match(%r{\Aasterism/([^/]+)}))
        "a_node:#{m[1]}"
      elsif (m = key.to_s.match(%r{\Aroom/([^/]+)/asterism/([^/]+)}))
        "a_node:room/#{m[1]}/#{m[2]}"
      end
    end

    # The node a token in a router's table belongs to (an Asterism node or a
    # ROS 2 node), or nil.
    def token_node(key)
      if (id = asterism_node_id(key))
        id
      elsif (t = self.class.parse_ros_token(key))
        id = "r_node:#{self.class.norm_zid(t[:zid])}/#{t[:nid]}"
      end
      id if id && @nodes[id]
    end

    # The routers a token came through, as a router's table lists them
    # ("routers"): known routers other than the one that lists it.
    def note_via(via, key, who, own)
      nid = token_node(key)
      return unless nid
      Array(who["routers"]).each do |z|
        nz = self.class.norm_zid(z)
        next if nz == own
        rid = @session_of[nz]
        via[nid][rid] = true if rid&.start_with?("router:")
      end
    end

    # A node no readable router carries (its router's admin space is not
    # readable: an ACL in the way) but that a readable router's token table
    # says came through another router: a "via_router" edge, node -> that
    # router. What is behind the router is not visible. When some of the
    # routers named are not readable, only those: a readable one would
    # have carried the node.
    def link_via(via, admin)
      read = admin.keys.to_h { [ "router:#{self.class.norm_zid(_1)}", true ] }
      carried = @edges.each_value.filter_map { _1["target"] if _1["kind"] == "carries" }.to_h { [ _1, true ] }
      via.each do |nid, routers|
        next if carried[nid]
        rids = routers.keys
        unread = rids.reject { read[_1] }
        (unread.empty? ? rids : unread).each { edge(nid, _1, "via_router", "via") }
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
        next if n["data"]["room"] # a room's nodes are not the registry's
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

    # The router an Asterism node comes through (its session's router, or
    # the router of its "via_router" edge).
    def via_router(n)
      sid = @edges.values.find { _1["kind"] == "carries" && _1["target"] == n["id"] }&.dig("source")
      rid = if sid
        @edges.values.find { _1["kind"] == "session" && _1["target"] == sid }&.dig("source")
      else
        @edges.values.find { _1["kind"] == "via_router" && _1["source"] == n["id"] }&.dig("target")
      end
      r = rid && @nodes[rid]
      r && (r["data"]["name"] || r["label"])
    end

    # ---------------------------------------------------------------- output

    # With the default drawing's parts (Bridge::Connections), the groups of
    # ROS 2 nodes (Bridge::Groups) and the marks and registry box
    # (Bridge::Marks) added.
    def to_h
      self.class.derive({ "nodes" => @nodes.keys.sort.map { @nodes[_1] }, "edges" => @edges.keys.sort.map { @edges[_1] } },
                        cloud: @cloud, names: @names, gateways: @gateways, icons: @icons)
    end

    # The derived parts on a graph in to_h form (live, or recorded: the
    # rewind runs it again on recorded graphs, with today's names).
    # gateways: addresses to take as gateways besides the ones the graph
    # shows (Bridge::Gateways).
    # icons: the icon hashes the store has (nil: none is linked).
    def self.derive(graph, cloud: nil, names: [], gateways: [], icons: nil)
      Marks.apply(Groups.apply(Connections.apply(graph), names: names || [], gateways: gateways || []), cloud: cloud,
                                                                                                         icons: icons)
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
