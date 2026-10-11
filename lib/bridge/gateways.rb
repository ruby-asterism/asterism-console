# The gateways (V2.4): addresses that many machines come from, so that the
# address says nothing about the machine. Docker's published ports are the
# case at hand: on Docker Desktop (and WSL), every device on the LAN that
# reaches zenohd through the published 7447 arrives from the Docker
# network's gateway (e.g. 172.20.0.1), and so does a process on the host.
# Bridge::Groups does not fold the ROS 2 nodes that come from one.
#
# Two ways to know one:
#
#   - Seen in the graph (detect): the bridge knows its own end of its link
#     to the router (Session#links, "src"; kept as the router's data
#     "bridge_link" "local"), and the router says where the bridge's
#     sessions come from (their "address"). When the two IP addresses
#     differ, something between them rewrites the address: the address the
#     router sees is a gateway (at that router). The bridge reaches zenohd
#     the way the LAN does (the published port), so this finds the gateway
#     of the setup this console was made for, with nothing to set, and the
#     recordings keep it (a recording made before V2.4 has no "local").
#   - Configured (ASTERISM_GATEWAY_IPS, comma or space separated): for the
#     setups where the bridge does not go through the gateway the devices
#     do (the bridge in a container on the Docker network, or on another
#     host). Applies at every router.
#
# Where neither tells, nothing is a gateway and the nodes fold by address
# as in V2.3 (two devices behind one NAT look like one machine).
module Bridge
  module Gateways
    module_function

    # The configured gateway addresses (ASTERISM_GATEWAY_IPS).
    def configured(env = ENV)
      env["ASTERISM_GATEWAY_IPS"].to_s.split(/[\s,]+/).filter_map { normalize(_1) }.uniq
    end

    def normalize(ip)
      s = ip.to_s.strip.delete_prefix("[").delete_suffix("]").downcase
      s = s.sub(/\A::ffff:(?=\d+\.\d+\.\d+\.\d+\z)/, "")
      s.empty? ? nil : s
    end

    # The gateways the graph shows: { router id => [ip, ...] }, from the
    # bridge's own sessions (data "self") whose address at a router is not
    # the bridge's own end of its link to that router.
    def detect(graph)
      nodes = graph["nodes"].to_a.to_h { [ _1["id"], _1 ] }
      router_of = {}
      graph["edges"].to_a.each do |e|
        router_of[e["target"]] = e["source"] if e["kind"] == "session" && !e["folded"]
      end
      out = {}
      nodes.each_value do |s|
        next unless s["kind"] == "session" && s.dig("data", "self")
        rid = router_of[s["id"]]
        local = Groups.ip_of(nodes[rid]&.dig("data", "bridge_link", "local"))
        seen = Groups.ip_of(s.dig("data", "address"))
        next unless local && seen && local != seen
        (out[rid] ||= []) << seen unless out[rid]&.include?(seen)
      end
      out
    end

    # Every gateway address in a graph (any router), for the rewind of a
    # recording that does not show its own.
    def detected_ips(graph)
      detect(graph).values.flatten.uniq
    end
  end
end
