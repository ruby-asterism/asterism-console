require "test_helper"

# Bridge::Groups: the ROS 2 nodes that come from the same IP address folded
# into one machine (V2.3), and the machine names matched by node names.
class Bridge::GroupsTest < ActiveSupport::TestCase
  ROUTER = "c1df5ae4175c56de269da5532ff80c51"
  ROVER = "a085c6bfd204b2bf9ddeb5c81bfbd7b3"   # peer: one process with two nodes (192.0.2.5)
  ROVER2 = "b085c6bfd204b2bf9ddeb5c81bfbd7b3"  # peer: another process on the same machine
  BOARD = "172c3662b323eeb866864f759dad074d"   # client: a board with one ROS 2 node (192.0.2.9)
  ASTER = "9fd8e2c3751738c83869543407a78303"   # client: an Asterism node on the rover's machine

  QOS = "::,10:,:,:,,"
  STRING = "std_msgs::msg::dds_::String_/RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18"

  def session(zid, whatami, ip, port)
    { "links" => [ { "dst" => "tcp/[::ffff:#{ip}]:#{port}", "src" => "tcp/[::ffff:192.0.2.2]:7447" } ],
      "peer" => zid, "whatami" => whatami }
  end

  def admin(rover_ip: "192.0.2.5")
    { ROUTER => {
      "router" => {
        "locators" => [ "tcp/192.0.2.2:7447" ], "metadata" => { "name" => "zenohd-home" }, "plugins" => {},
        "sessions" => [ session(ROVER, "peer", rover_ip, 40001), session(ROVER2, "peer", rover_ip, 40002),
                       session(BOARD, "client", "192.0.2.9", 50001), session(ASTER, "client", rover_ip, 40003) ],
        "version" => "v1.10.1", "zid" => ROUTER
      },
      "linkstate" => {},
      "tokens" => { "asterism/cruby" => { "routers" => [], "peers" => [], "clients" => [ ASTER ] } }
    } }
  end

  def pub(zid, nid, node, topic, eid = 1) = "@ros2_lv/0/#{zid}/#{nid}/#{eid}/MP/%/%/#{node}/%#{topic}/#{STRING}/#{QOS}"
  def sub(zid, nid, node, topic, eid = 2) = "@ros2_lv/0/#{zid}/#{nid}/#{eid}/MS/%/%/#{node}/%#{topic}/#{STRING}/#{QOS}"

  def ros
    [ "@ros2_lv/0/#{ROVER}/0/0/NN/%/%/controller_manager",
      "@ros2_lv/0/#{ROVER}/1/0/NN/%/%/diff_drive_controller",
      "@ros2_lv/0/#{ROVER2}/0/0/NN/%/%/camera_jpeg",
      "@ros2_lv/0/#{BOARD}/0/0/NN/%/%/fmruby_drive",
      # inside the rover: controller_manager -> diff_drive_controller
      pub(ROVER, 0, "controller_manager", "inner"), sub(ROVER, 1, "diff_drive_controller", "inner"),
      # rover -> board, board -> rover
      pub(ROVER, 1, "diff_drive_controller", "odom", 3), sub(BOARD, 0, "fmruby_drive", "odom"),
      pub(ROVER2, 0, "camera_jpeg", "image"), sub(BOARD, 0, "fmruby_drive", "image", 4),
      pub(BOARD, 0, "fmruby_drive", "cmd_vel", 5), sub(ROVER, 1, "diff_drive_controller", "cmd_vel", 6),
      "@ros2_lv/0/#{ROVER}/0/7/SS/%/%/controller_manager/%controller_manager%list/#{STRING}/#{QOS}" ]
  end

  def graph(names: [], rover_ip: "192.0.2.5")
    Bridge::Graph.build(admin: admin(rover_ip: rover_ip), asterism: %w[asterism/cruby], ros: ros, names: names).to_h
  end

  def node(g, id)
    g["nodes"].find { _1["id"] == id } || flunk("no node #{id}")
  end

  def edges(g, kind, folded: nil)
    g["edges"].select { _1["kind"] == kind && (folded.nil? || !!_1["folded"] == folded) }
              .map { [ _1["source"], _1["target"] ] }.sort
  end

  GROUP = "r_group:192.0.2.5".freeze
  CM = "r_node:#{ROVER}/0".freeze
  DD = "r_node:#{ROVER}/1".freeze
  CAM = "r_node:#{ROVER2}/0".freeze
  DRIVE = "r_node:#{BOARD}/0".freeze

  test "the IP of a locator" do
    assert_equal "192.0.2.5", Bridge::Groups.ip_of("tcp/[::ffff:192.0.2.5]:43764")
    assert_equal "192.0.2.5", Bridge::Groups.ip_of("tcp/192.0.2.5:7447")
    assert_equal "2001:db8::1", Bridge::Groups.ip_of("tls/[2001:DB8::1]:7448")
    assert_equal "fe80::1", Bridge::Groups.ip_of("tcp/[fe80::1%eth0]:7447")
    assert_equal "192.0.2.5", Bridge::Groups.ip_of("udp/192.0.2.5:7447?iface=eth0")
    assert_nil Bridge::Groups.ip_of(nil)
  end

  test "the ROS 2 nodes of one IP are one group, named by the IP; a lone node and Asterism stay out" do
    g = graph
    group = node(g, GROUP)
    assert_equal [ "r_group", "ros", "192.0.2.5 (3 ROS 2 nodes)" ], group.values_at("kind", "layer", "label")
    assert_equal [ CM, DD, CAM ], group["data"]["members"]
    assert_equal %w[/camera_jpeg /controller_manager /diff_drive_controller], group["data"]["member_names"]
    assert_nil group["data"]["name"]
    [ CM, DD, CAM ].each { assert_equal GROUP, node(g, _1)["data"]["group"] }
    assert_nil node(g, DRIVE)["data"]["group"], "one node from its IP: not a group"
    assert_nil node(g, "a_node:cruby")["data"]["group"], "Asterism nodes are not grouped"
    assert_equal 1, g["nodes"].count { _1["kind"] == "r_group" }
  end

  test "folded copies of the edges: topics from and to the group, nothing inside it" do
    g = graph
    assert_equal [ [ GROUP, DRIVE ], [ DRIVE, GROUP ] ], edges(g, "topic_link", folded: true)
    out = g["edges"].find { _1["id"] == "topic_link:#{GROUP}->#{DRIVE}" }
    assert_equal %w[r_topic:0/image r_topic:0/odom], out["topics"]
    assert_equal "/image\n/odom", out["label"]
    refute g["edges"].any? { _1["folded"] && _1["source"] == _1["target"] }, "no loop for the topic inside"
    assert_equal [ "r_topic:0/inner" ], node(g, GROUP)["data"]["internal_topics"]
    # The originals stay, for the group opened.
    assert_includes edges(g, "topic_link", folded: false), [ CM, DD ]
    # One line to the router for the group, with both sessions.
    attach = g["edges"].find { _1["id"] == "attach:#{GROUP}->router:#{ROUTER}" }
    assert_equal [ "peer", [ ROVER, ROVER2 ].sort ], [ attach["label"], attach["sessions"].sort ]
    # Topics as nodes, and Sessions as points.
    assert_includes edges(g, "publishes", folded: true), [ GROUP, "r_topic:0/odom" ]
    assert_includes edges(g, "subscribes", folded: true), [ "r_topic:0/cmd_vel", GROUP ]
    assert_includes edges(g, "carries", folded: true), [ "session:#{ROVER}", GROUP ]
  end

  test "the group's services and topics with no counterpart, added up" do
    group = node(graph, GROUP)
    assert_equal [ [ "/controller_manager/list", CM ] ], group["data"]["services"].map { _1.values_at("name", "node") }
    assert_equal 2, group["data"]["connections"].size
  end

  test "an edge between two groups gets a copy for each way of folding" do
    g = Bridge::Graph.build(admin: admin.tap { |a|
      a[ROUTER]["router"]["sessions"] << session("d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1", "client", "192.0.2.9", 50002)
    }, ros: ros + [ "@ros2_lv/0/d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1/0/0/NN/%/%/fmruby_view" ]).to_h
    board = "r_group:192.0.2.9"
    assert node(g, board)
    links = edges(g, "topic_link", folded: true)
    assert_includes links, [ GROUP, board ]
    assert_includes links, [ GROUP, DRIVE ]
    assert_includes links, [ board, DD ]
    assert_includes links, [ board, GROUP ]
  end

  test "names: matched by node names, not by the IP" do
    names = [ { "id" => 1, "name" => "rover", "members" => %w[/camera_jpeg /controller_manager /diff_drive_controller] } ]
    g = graph(names: names, rover_ip: "192.0.2.77")
    group = node(g, "r_group:192.0.2.77")
    assert_equal [ "rover (3 ROS 2 nodes)", "rover", 1 ], [ group["label"], group["data"]["name"], group["data"]["name_id"] ]
  end

  test "names: half of the larger set must match" do
    m = %w[/a /b /c /d]
    assert Bridge::Groups.overlap?(m, %w[/a /b /x /y]), "2 of 4 and 4"
    refute Bridge::Groups.overlap?(m, %w[/a /x /y /z]), "1 of 4"
    assert Bridge::Groups.overlap?(m, %w[/a /b]), "2 of max(4, 2)"
    refute Bridge::Groups.overlap?(m, %w[/a]), "1 of max(4, 1)"
    refute Bridge::Groups.overlap?(%w[/a /b], %w[/a /x /y /z /w]), "1 of max(2, 5)"
    refute Bridge::Groups.overlap?(m, [])
  end

  test "names: the best overlap first, a name for one group only" do
    groups = { "g1" => %w[/a /b /c /d], "g2" => %w[/a /b /c /x] }
    names = [ { "id" => 1, "name" => "one", "members" => %w[/a /b /c /d] },
              { "id" => 2, "name" => "two", "members" => %w[/a /b /c /x] } ]
    assert_equal({ "g1" => "one", "g2" => "two" }, Bridge::Groups.match(groups, names).transform_values { _1["name"] })
    # Two of the same machine (the same node names): the name goes to one.
    same = { "g1" => %w[/a /b], "g2" => %w[/a /b] }
    got = Bridge::Groups.match(same, [ { "id" => 1, "name" => "rover", "members" => %w[/a /b] } ])
    assert_equal 1, got.size
    # Two names for one machine: the newer one.
    got = Bridge::Groups.match({ "g1" => %w[/a /b] }, [ { "id" => 1, "name" => "old", "members" => %w[/a /b] },
                                                      { "id" => 2, "name" => "new", "members" => %w[/a /b] } ])
    assert_equal "new", got["g1"]["name"]
  end

  test "a group that changed too much goes back to its IP" do
    names = [ { "id" => 1, "name" => "rover", "members" => %w[/w /x /y /z /camera_jpeg] } ]
    assert_equal "192.0.2.5 (3 ROS 2 nodes)", node(graph(names: names), GROUP)["label"]
  end

  test "idempotent, and on a graph from before V2.3" do
    names = [ { "id" => 1, "name" => "rover", "members" => %w[/camera_jpeg /controller_manager] } ]
    g = graph(names: names)
    assert_equal g, Bridge::Groups.apply(g, names: names)
    bare = Bridge::Groups.apply(g, names: [])
    assert_equal "192.0.2.5 (3 ROS 2 nodes)", node(bare, GROUP)["label"]
    old = { "nodes" => g["nodes"].reject { _1["kind"] == "r_group" }.map { _1.merge("data" => _1["data"].except("group")) },
            "edges" => g["edges"].reject { _1["folded"] } }
    assert_equal g, Bridge::Groups.apply(old, names: names)
  end

  test "a member leaving: the group goes when one node is left" do
    g = Bridge::Graph.build(admin: admin, ros: ros.reject { _1.include?(ROVER2) || _1.include?("diff_drive_controller") }).to_h
    refute g["nodes"].any? { _1["kind"] == "r_group" }
    refute g["edges"].any? { _1["folded"] }
    assert_nil node(g, CM)["data"]["group"]
  end
end
