require "test_helper"

# Bridge::Gateways and its use in Bridge::Groups (V2.4): the ROS 2 nodes
# that come from a gateway's address (Docker's published ports: every LAN
# device arrives from the Docker network's gateway) are not folded.
class Bridge::GatewaysTest < ActiveSupport::TestCase
  ROUTER = "c1df5ae4175c56de269da5532ff80c51"
  SELF = "5e1f00000000000000000000000000aa"   # the bridge (client), through the published port
  BOARD1 = "b1000000000000000000000000000001" # a board on the LAN (client), through it too
  BOARD2 = "b2000000000000000000000000000002" # another one
  ROVER = "a085c6bfd204b2bf9ddeb5c81bfbd7b3"  # a container on the Docker network: two nodes
  ROVER2 = "a185c6bfd204b2bf9ddeb5c81bfbd7b3"

  GW = "192.0.2.1"

  def session(zid, whatami, ip, port)
    { "links" => [ { "dst" => "tcp/[::ffff:#{ip}]:#{port}", "src" => "tcp/[::ffff:192.0.2.2]:7447" } ],
      "peer" => zid, "whatami" => whatami }
  end

  def admin(self_ip: GW)
    { ROUTER => {
      "router" => {
        "locators" => [ "tcp/192.0.2.2:7447" ], "metadata" => { "name" => "zenohd-home" }, "plugins" => {},
        "sessions" => [ session(SELF, "client", self_ip, 42320), session(BOARD1, "client", GW, 37488),
                       session(BOARD2, "client", GW, 37490), session(ROVER, "peer", "192.0.2.5", 40001),
                       session(ROVER2, "peer", "192.0.2.5", 40002) ],
        "version" => "v1.10.1", "zid" => ROUTER
      },
      "linkstate" => {}, "tokens" => {}
    } }
  end

  def ros
    [ "@ros2_lv/0/#{BOARD1}/0/0/NN/%/%/fmruby_cam",
      "@ros2_lv/0/#{BOARD2}/0/0/NN/%/%/cruby_rover",
      "@ros2_lv/0/#{ROVER}/0/0/NN/%/%/controller_manager",
      "@ros2_lv/0/#{ROVER2}/0/0/NN/%/%/camera_jpeg" ]
  end

  def graph(local: "tcp/127.0.0.1:38722", self_ip: GW, gateways: [])
    own = local ? { ROUTER => { "protocol" => "tcp", "local" => local } } : {}
    Bridge::Graph.build(admin: admin(self_ip: self_ip), ros: ros, self_node: "console", self_zids: [ SELF ],
                        own_links: own, gateways: gateways).to_h
  end

  def node(g, id)
    g["nodes"].find { _1["id"] == id } || flunk("no node #{id}")
  end

  def groups(g) = g["nodes"].select { _1["kind"] == "r_group" }.map { _1["id"] }

  test "configured: comma or space separated, normalized" do
    env = { "ASTERISM_GATEWAY_IPS" => " 172.20.0.1, [::ffff:10.0.0.1]  FE80::1,172.20.0.1" }
    assert_equal %w[172.20.0.1 10.0.0.1 fe80::1], Bridge::Gateways.configured(env)
    assert_equal [], Bridge::Gateways.configured({})
  end

  test "detected: the bridge's session seen from another address than its own end" do
    g = graph
    assert_equal({ "router:#{ROUTER}" => [ GW ] }, Bridge::Gateways.detect(g))
    assert_equal "tcp/127.0.0.1:38722", node(g, "router:#{ROUTER}")["data"]["bridge_link"]["local"]
  end

  test "the nodes from a detected gateway are not folded; the rest are" do
    g = graph
    assert_equal [ "r_group:192.0.2.5" ], groups(g)
    [ BOARD1, BOARD2 ].each do |z|
      d = node(g, "r_node:#{z}/0")["data"]
      assert_nil d["group"]
      assert_equal({ "ip" => GW, "how" => "detected" }, d["gateway"])
    end
    assert_nil node(g, "r_node:#{ROVER}/0")["data"]["gateway"]
    assert_equal "r_group:192.0.2.5", node(g, "r_node:#{ROVER}/0")["data"]["group"]
  end

  test "no translation, no gateway: folded by address as in V2.3" do
    g = graph(local: "tcp/#{GW}:42320")
    assert_equal({}, Bridge::Gateways.detect(g))
    assert_equal [ "r_group:#{GW}", "r_group:192.0.2.5" ].sort, groups(g).sort
    # Without the bridge's end (a recording from before V2.4): the same.
    g = graph(local: nil)
    assert_includes groups(g), "r_group:#{GW}"
  end

  test "configured gateways apply where nothing is detected" do
    g = graph(local: nil, gateways: [ GW ])
    assert_equal [ "r_group:192.0.2.5" ], groups(g)
    assert_equal({ "ip" => GW, "how" => "given" }, node(g, "r_node:#{BOARD1}/0")["data"]["gateway"])
  end

  test "idempotent; a gateway no more brings the group back" do
    g = graph(local: nil, gateways: [ GW ])
    assert_equal g, Bridge::Graph.derive(g, gateways: [ GW ])
    again = Bridge::Graph.derive(g, gateways: [])
    assert_includes groups(again), "r_group:#{GW}"
    assert_nil node(again, "r_node:#{BOARD1}/0")["data"]["gateway"]
    assert_equal "r_group:#{GW}", node(again, "r_node:#{BOARD1}/0")["data"]["group"]
  end
end
