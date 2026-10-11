# ROS 2 nodes folded by machine (V2.3), derived from a graph in to_h form
# after Bridge::Connections (it reads the nodes' data "connections"), so the
# same code serves the live graph (Graph#to_h) and the rewind of recordings
# (RecordingsController#graph).
#
# ROS 2 does not say which machine or process a node runs in. The one hint
# is the address its session comes from: the ROS 2 nodes whose session
# comes from the same IP address, two or more of them, make one group.
# Asterism nodes are left out (they have their own nesting).
#
# Added:
#   - an "r_group" node per group ("r_group:<ip>", layer "ros"), labelled
#     "<name or ip> (N ROS 2 nodes)". Data: "ip", "members" (node ids),
#     "member_names" (ROS 2 node names), "name" / "name_id" / "named_members"
#     when a machine name matches (below), "services", "clients" and
#     "unmatched" of all its nodes (each entry with its "node"),
#     "connections" (its nodes' sessions, once each) and "internal_topics"
#     (topics between two of its own nodes).
#   - data "group" on each member r_node.
#   - folded copies of the edges that touch a member (FOLDABLE kinds), with
#     the member replaced by its group ("folded" true). An edge between two
#     groups gets a copy for each way of folding them (A folded, B folded,
#     both). A copy whose ends fall into the same group is not made: inside a
#     folded group nothing is drawn (the details list those topics). Copies
#     that end up between the same two ends are merged (topic_link: their
#     topics; attach: their sessions and roles).
#
# The page shows a group's node while it is folded and its members while it
# is open; an edge shows when both its ends show, so the right copy appears.
#
# Names: machine names live in the console's database (MachineName) as a
# name and the ROS 2 node names it was given for, not the IP (which
# changes). A group takes the name whose node names overlap its own enough:
# shared names at least half of the larger of the two sets
# (2 * |G & N| >= max(|G|, |N|)). When several pairs qualify, the best
# overlap (Jaccard, |G & N| / |G | N|) wins first, then the newer name; a
# name goes to one group and a group takes one name.
#
# apply removes what it added before adding it again (idempotent).
module Bridge
  module Groups
    KIND = "r_group".freeze
    FOLDABLE = %w[topic_link attach publishes subscribes carries peer_link].freeze

    module_function

    # The IP address of a locator: "tcp/[::ffff:192.0.2.5]:43764" ->
    # "192.0.2.5", "tcp/192.0.2.5:7447" -> "192.0.2.5", "tcp/[fe80::1%eth0]:1"
    # -> "fe80::1".
    def ip_of(locator)
      s = locator.to_s.split(/[?#]/).first.to_s.sub(%r{\A[a-z0-9-]+/}i, "")
      host = s[/\A\[([^\]]+)\]/, 1] || s.sub(/:\d+\z/, "")
      host = host.split("%").first.to_s.sub(/\A::ffff:(?=\d+\.\d+\.\d+\.\d+\z)/i, "")
      host.empty? ? nil : host.downcase
    end

    # The IP a ROS 2 node comes from (its first session with an address).
    def node_ip(node)
      Array(node.dig("data", "connections")).each do |c|
        ip = ip_of(c["address"])
        return ip if ip
      end
      nil
    end

    # Whether a group of node names (members) takes a stored name's node
    # names (named): the shared ones are at least half of the larger set.
    def overlap?(members, named)
      a = members.uniq
      b = named.uniq
      shared = (a & b).size
      shared.positive? && 2 * shared >= [ a.size, b.size ].max
    end

    def score(members, named)
      union = (members | named).size
      union.zero? ? 0.0 : (members & named).size.to_f / union
    end

    # groups: { gid => member names }, names: [{ "id", "name", "members" }].
    # Returns { gid => name entry }.
    def match(groups, names)
      pairs = []
      groups.each do |gid, members|
        Array(names).each do |n|
          named = Array(n["members"]).map(&:to_s)
          next unless overlap?(members, named)
          pairs << [ score(members, named), n["id"].to_i, gid, n ]
        end
      end
      out = {}
      used = {}
      pairs.sort_by { |s, id, gid, _| [ -s, -id, gid ] }.each do |_, id, gid, n|
        next if out.key?(gid) || used[id]
        out[gid] = n
        used[id] = true
      end
      out
    end

    def apply(graph, names: [])
      nodes = graph["nodes"].to_a.reject { _1["kind"] == KIND }.map do |n|
        n["kind"] == "r_node" && n["data"].is_a?(Hash) && n["data"].key?("group") ? n.merge("data" => n["data"].except("group")) : n
      end
      edges = graph["edges"].to_a.reject { _1["folded"] }

      by_ip = Hash.new { |h, k| h[k] = [] }
      nodes.each do |n|
        next unless n["kind"] == "r_node"
        ip = node_ip(n)
        by_ip[ip] << n if ip
      end
      by_ip.select! { |_, list| list.size >= 2 }

      group_of = {}
      member_names = {}
      by_ip.each do |ip, list|
        gid = "#{KIND}:#{ip}"
        list.each { group_of[_1["id"]] = gid }
        member_names[gid] = list.map { _1["label"].to_s }.uniq.sort
      end
      named = match(member_names, names)

      groups = by_ip.sort.map do |ip, list|
        gid = "#{KIND}:#{ip}"
        list = list.sort_by { _1["id"] }
        ids = list.map { _1["id"] }
        entry = named[gid]
        data = { "ip" => ip, "members" => ids, "member_names" => member_names[gid] }
        if entry
          data["name"] = entry["name"].to_s
          data["name_id"] = entry["id"]
          data["named_members"] = Array(entry["members"]).map(&:to_s).sort
        end
        %w[services clients unmatched].each do |key|
          all = list.flat_map { |m| Array(m.dig("data", key)).map { _1.merge("node" => m["id"]) } }
          data[key] = all unless all.empty?
        end
        data["connections"] = list.flat_map { Array(_1.dig("data", "connections")) }.uniq { _1["zid"] }
        data["domain"] = list.first.dig("data", "domain")
        internal = edges.select { _1["kind"] == "topic_link" && ids.include?(_1["source"]) && ids.include?(_1["target"]) }
        data["internal_topics"] = internal.flat_map { Array(_1["topics"]) }.uniq.sort
        label = "#{data['name'] || ip} (#{ids.size} ROS 2 nodes)"
        { "id" => gid, "kind" => KIND, "layer" => "ros", "label" => label, "data" => data.compact }
      end
      nodes = nodes.map do |n|
        gid = group_of[n["id"]]
        gid ? n.merge("data" => (n["data"] || {}).merge("group" => gid)) : n
      end
      by_id = nodes.to_h { [ _1["id"], _1 ] }
      groups.each { by_id[_1["id"]] = _1 }

      folded = {}
      edges.each do |e|
        next unless FOLDABLE.include?(e["kind"])
        involved = [ group_of[e["source"]], group_of[e["target"]] ].compact.uniq
        next if involved.empty?
        (1..involved.size).flat_map { involved.combination(_1).to_a }.each do |fold|
          s = fold.include?(group_of[e["source"]]) ? group_of[e["source"]] : e["source"]
          t = fold.include?(group_of[e["target"]]) ? group_of[e["target"]] : e["target"]
          next if s == t
          s, t = [ s, t ].sort if e["kind"] == "peer_link"
          id = "#{e['kind']}:#{s}->#{t}"
          copy = (folded[id] ||= e.merge("id" => id, "source" => s, "target" => t, "folded" => true)
                                     .except("topics", "sessions", "roles", "shared"))
          merge_into(copy, e)
          layer = [ by_id[s]&.dig("layer"), by_id[t]&.dig("layer") ].compact.uniq
          copy["layer"] = layer.size == 1 ? layer[0] : "cross"
        end
      end
      folded.each_value do |c|
        next unless c["kind"] == "topic_link"
        c["label"] = c["topics"].map { by_id[_1]&.dig("label") || _1 }.join("\n")
      end

      all_nodes = nodes + groups
      all_edges = edges + folded.values
      { "nodes" => all_nodes.sort_by { _1["id"] }, "edges" => all_edges.sort_by { _1["id"] } }.merge(
        graph.except("nodes", "edges")
      )
    end

    def merge_into(copy, e)
      case e["kind"]
      when "topic_link"
        copy["topics"] = ((copy["topics"] || []) + Array(e["topics"])).uniq.sort
      when "attach"
        copy["sessions"] = ((copy["sessions"] || []) + Array(e["sessions"])).uniq
        copy["roles"] = ((copy["roles"] || []) + Array(e["roles"])).uniq.sort
        copy["label"] = copy["roles"].join(" / ") unless copy["roles"].empty?
        copy["shared"] = [ copy["shared"] || 0, e["shared"] || 0 ].max if e["shared"]
      end
    end
  end
end
