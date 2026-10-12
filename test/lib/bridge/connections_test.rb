require "test_helper"

# Bridge::Connections: the default drawing (V2.1), nodes joined to their
# router directly, from graphs built by Bridge::Graph (made-up IDs).
class Bridge::ConnectionsTest < ActiveSupport::TestCase
  ROUTER = "c1df5ae4175c56de269da5532ff80c51"
  BOARD = "172c3662b323eeb866864f759dad074d"   # client: an Asterism board
  CONSOLE = "9fd8e2c3751738c83869543407a78303" # client: the bridge's object layer
  READER = "05b7aa4274bb226aea1dbd76825220ef"  # client: the bridge's reader, carries nothing
  ROS = "a085c6bfd204b2bf9ddeb5c81bfbd7b3"     # peer: a ROS 2 process with two nodes
  BARE = "d00dfeed00000000000000000000000a"    # client: declares nothing
  BARE2 = "d00dfeed00000000000000000000000b"   # peer: declares nothing
  LONE = "e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"    # peer: connected to the console only

  QOS = "::,10:,:,:,,"
  STRING = "std_msgs::msg::dds_::String_/RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18"

  def session(zid, whatami, port, protocol = "tcp")
    { "links" => [ { "dst" => "#{protocol}/[::ffff:192.0.2.10]:#{port}", "src" => "#{protocol}/[::ffff:192.0.2.2]:7447" } ],
      "peer" => zid, "whatami" => whatami }
  end

  def admin(extra = [])
    { ROUTER => {
      "router" => {
        "locators" => [ "tcp/192.0.2.2:7447" ], "metadata" => { "name" => "zenohd-home" }, "plugins" => {},
        "sessions" => [ session(BOARD, "client", 1), session(CONSOLE, "client", 2),
                       session(READER.sub(/\A0+/, ""), "client", 3), session(ROS, "peer", 4) ] + extra,
        "version" => "v1.10.1", "zid" => ROUTER
      },
      "linkstate" => {},
      "tokens" => {
        "asterism/fmruby-aaaaaa/demo" => { "routers" => [], "peers" => [], "clients" => [ BOARD ] },
        "asterism/fmruby-aaaaaa/demo/screen" => { "routers" => [], "peers" => [], "clients" => [ BOARD ] },
        "asterism/console/console" => { "routers" => [], "peers" => [], "clients" => [ CONSOLE ] }
      }
    } }
  end

  def ros(zid = ROS)
    [ "@ros2_lv/0/#{zid}/0/0/NN/%/%/controller_manager",
     "@ros2_lv/0/#{zid}/1/0/NN/%/%/diff_drive_controller",
     "@ros2_lv/0/#{zid}/0/1/MP/%/%/controller_manager/%chatter/#{STRING}/#{QOS}",
     "@ros2_lv/0/#{zid}/1/2/MS/%/%/diff_drive_controller/%chatter/#{STRING}/#{QOS}" ]
  end

  def graph(**opts)
    Bridge::Graph.build(admin: admin(opts.delete(:extra) || []), asterism: %w[asterism/fmruby-aaaaaa/demo
      asterism/fmruby-aaaaaa/demo/screen asterism/console/console], ros: ros + (opts.delete(:ros) || []),
                        self_node: "console", self_zids: [ READER ], **opts).to_h
  end

  def node(g, id)
    g["nodes"].find { _1["id"] == id } || flunk("no node #{id}")
  end

  def attach(g, source)
    g["edges"].find { _1["kind"] == "attach" && _1["source"] == source }
  end

  test "each node is joined to its router, the line labelled with its role" do
    g = graph
    rid = "router:#{ROUTER}"
    assert_equal [ rid, "client", "cross" ], attach(g, "a_node:fmruby-aaaaaa").values_at("target", "label", "layer")
    assert_equal [ rid, "peer" ], attach(g, "r_node:#{ROS}/0").values_at("target", "label")
    # Apps and objects have no line of their own: their node's box has it.
    assert_nil attach(g, "a_app:fmruby-aaaaaa/demo")
    # The sessions stay for "Sessions as points".
    assert g["nodes"].any? { _1["kind"] == "session" }
    assert g["edges"].any? { _1["kind"] == "carries" }
  end

  test "a node's details: its session's Zenoh ID, role, address, link and router" do
    c = node(graph, "a_node:fmruby-aaaaaa")["data"]["connections"]
    assert_equal 1, c.size
    assert_equal({ "zid" => BOARD, "role" => "client", "address" => "tcp/[::ffff:192.0.2.10]:1", "protocol" => "tcp",
                   "router" => "router:#{ROUTER}", "router_label" => "router zenohd-home", "self" => false,
                   "nodes" => [ "a_node:fmruby-aaaaaa" ] }, c[0].except("links"))
  end

  test "the console's reader session, which carries no token, belongs to the console" do
    g = graph
    zids = node(g, "a_node:console")["data"]["connections"].map { _1["zid"] }
    assert_equal [ CONSOLE, READER.sub(/\A0+/, "") ].sort, zids.sort
    assert_equal 2, attach(g, "a_node:console")["sessions"].size
    assert_equal "client", attach(g, "a_node:console")["label"], "one line, the role once"
    assert_empty g["nodes"].select { _1["kind"] == "others" }
  end

  test "a session with several nodes: a line from each, marked shared" do
    g = graph
    # (The folded copy from the group of the two, Bridge::Groups, aside.)
    lines = g["edges"].select { _1["kind"] == "attach" && _1["sessions"] == [ ROS ] && !_1["folded"] }
    assert_equal [ "r_node:#{ROS}/0", "r_node:#{ROS}/1" ], lines.map { _1["source"] }.sort
    assert(lines.all? { _1["shared"] == 2 })
    assert_equal [ "r_node:#{ROS}/0", "r_node:#{ROS}/1" ], node(g, "r_node:#{ROS}/1")["data"]["connections"][0]["nodes"]
    assert_equal 1, attach(g, "a_node:fmruby-aaaaaa")["shared"]
  end

  test "sessions that carry no node are one 'other connections' node at their router" do
    g = graph(extra: [ session(BARE, "client", 5), session(BARE2, "peer", 6, "tls") ])
    others = g["nodes"].select { _1["kind"] == "others" }
    assert_equal 1, others.size
    o = others[0]
    assert_equal [ "others:#{ROUTER}", "infra", "2 other connections" ], o.values_at("id", "layer", "label")
    assert_equal [ [ "client", BARE, "tcp/[::ffff:192.0.2.10]:5" ], [ "peer", BARE2, "tls/[::ffff:192.0.2.10]:6" ] ],
                 o["data"]["sessions"].map { _1.values_at("role", "zid", "address") }
    assert_equal "router:#{ROUTER}", attach(g, o["id"])["target"]
    assert_equal "1 other connection", graph(extra: [ session(BARE, "client", 5) ])["nodes"].find { _1["kind"] == "others" }["label"]
  end

  test "peers connected without the router: a line between their nodes" do
    g = graph(ros: ros(LONE), peer_links: [ [ READER, LONE ], [ READER, ROS ] ])
    lone = node(g, "session:#{LONE}")
    assert_equal "peer", lone["data"]["whatami"]
    assert(g["edges"].any? { _1["kind"] == "peer_session" && [ _1["source"], _1["target"] ].sort == [ "session:#{LONE}", "session:#{READER.sub(/\A0+/, '')}" ].sort })
    links = g["edges"].select { _1["kind"] == "peer_link" }.map { [ _1["source"], _1["target"], _1["label"] ] }
    assert_includes links, [ "a_node:console", "r_node:#{LONE}/0", "peer" ]
    assert_includes links, [ "a_node:console", "r_node:#{ROS}/1", "peer" ]
    # No router has the lone peer: no line to a router, and its details say so.
    assert_nil attach(g, "r_node:#{LONE}/0")
    assert_nil node(g, "r_node:#{LONE}/0")["data"]["connections"][0]["router"]
  end

  test "a ROS 2 node on an Asterism node's session sits inside that node (G1b)" do
    brain = [ "@ros2_lv/0/#{BOARD}/0/0/NN/%/%/fmruby_brain_fmruby_aaaaaa",
              "@ros2_lv/0/#{BOARD}/0/1/MP/%/%/fmruby_brain_fmruby_aaaaaa/%chatter/#{STRING}/#{QOS}" ]
    g = graph(ros: brain)
    rn = node(g, "r_node:#{BOARD}/0")
    assert_equal "a_node:fmruby-aaaaaa", rn["parent"]
    assert_equal "a_node:fmruby-aaaaaa", rn["data"]["in_node"]
    assert_nil attach(g, "r_node:#{BOARD}/0"), "the board's line stands for the session"
    assert_equal "client", attach(g, "a_node:fmruby-aaaaaa")["label"]
    assert_equal [ "a_node:fmruby-aaaaaa", "r_node:#{BOARD}/0" ], rn["data"]["connections"][0]["nodes"]
    refute rn["data"].key?("group"), "not folded into a machine"
    # Its topics stay: the edge to the other process's subscriber.
    assert(g["edges"].any? { _1["source"] == "r_node:#{BOARD}/0" && _1["kind"] == "publishes" })
    # A ROS 2 process with nodes only stays outside.
    assert_nil node(g, "r_node:#{ROS}/0")["parent"]
    # Idempotent, also on a graph that has it already.
    assert_equal g, Bridge::Graph.derive(g)
  end

  test "apply is idempotent, and rebuilds a graph recorded without its parts" do
    g = graph(extra: [ session(BARE, "client", 5) ])
    assert_equal g, Bridge::Connections.apply(g)
    old = { "nodes" => g["nodes"].reject { _1["kind"] == "others" }.map { |n|
              %w[a_node r_node].include?(n["kind"]) ? n.merge("data" => n["data"].except("connections")) : n },
            "edges" => g["edges"].reject { %w[attach peer_link].include?(_1["kind"]) && !_1["folded"] } }
    assert_equal g, Bridge::Connections.apply(old)
  end

  test "a node gone, its line gone, as a diff" do
    a = graph
    b = Bridge::Graph.build(admin: admin, asterism: %w[asterism/console/console], ros: ros, self_node: "console",
                            self_zids: [ READER ]).to_h
    d = Bridge::Graph.diff(a, b)
    assert_includes d["remove_edges"], "attach:a_node:fmruby-aaaaaa->router:#{ROUTER}"
    assert_includes d["add_nodes"].map { _1["id"] }, "others:#{ROUTER}", "its session now carries nothing"
  end
end
