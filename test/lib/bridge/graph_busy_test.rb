require "test_helper"

# The V2 shape of the graph on a busy network (test/fixtures/files/
# busy_network.json: two routers, five Asterism nodes, twelve ROS 2 nodes
# with their parameter services, eighteen topics).
class Bridge::GraphBusyTest < ActiveSupport::TestCase
  INPUTS = Bridge::Fixture.load(Rails.root.join("test/fixtures/files/busy_network.json").to_s)

  def g
    @g ||= Bridge::Fixture.graph(INPUTS)
  end

  def node(id)
    g["nodes"].find { _1["id"] == id } || flunk("no node #{id}")
  end

  def ros(name)
    g["nodes"].find { _1["kind"] == "r_node" && _1["data"]["name"] == name } || flunk("no ROS 2 node #{name}")
  end

  def links
    g["edges"].select { _1["kind"] == "topic_link" }
  end

  def link(from, to)
    links.find { _1["source"] == ros(from)["id"] && _1["target"] == ros(to)["id"] }
  end

  test "services are attributes of their node, the parameter ones marked" do
    refute g["nodes"].any? { _1["kind"] == "r_service" }
    bc = ros("/base_controller")["data"]
    assert_equal 8, bc["services"].size
    assert_equal [ "/base_controller/reset_odometry" ], bc["services"].reject { _1["parameter"] }.map { _1["name"] }
    params = bc["services"].select { _1["parameter"] }.map { _1["name"].split("/").last }
    assert_equal Bridge::Graph::PARAMETER_SERVICES.sort, params.sort
    assert_equal "std_srvs/srv/Trigger", bc["services"].find { _1["name"].end_with?("reset_odometry") }["type"]
    # Calls are listed too.
    assert_equal [ "/slam_toolbox/save_map" ], ros("/navigator")["data"]["clients"].map { _1["name"] }
    # zenoh-pico's talker has no parameter services.
    assert_nil ros("/fmruby_talker_linux")["data"]["services"]
    assert Bridge::Graph.parameter_service?("/x/ns/get_type_description")
    refute Bridge::Graph.parameter_service?("/slam_toolbox/save_map")
  end

  test "topics are edges from publisher to subscriber, one per pair of nodes" do
    e = link("/talker", "/listener")
    assert_equal [ "r_topic:0/chatter" ], e["topics"]
    assert_equal "/chatter", e["label"]
    assert_equal "ros", e["layer"]
    # Two topics between the same pair share one edge.
    assert_equal %w[r_topic:0/odom r_topic:0/tf], link("/base_controller", "/slam_toolbox")["topics"]
    assert_equal "/odom\n/tf", link("/base_controller", "/slam_toolbox")["label"]
    # Two listeners (home and cloud) and two talkers: four edges for /chatter.
    assert_equal 4, links.count { _1["topics"].include?("r_topic:0/chatter") }
    # Both publish /tf and subscribe to it: no edge to itself.
    refute links.any? { _1["source"] == _1["target"] }
    # The topic nodes stay, with their ends, for the topics-as-nodes view.
    t = node("r_topic:0/chatter")["data"]
    assert t["matched"]
    assert_equal 2, t["publishers"].size
    assert_equal 2, t["subscribers"].size
    assert g["edges"].any? { _1["kind"] == "publishes" && _1["target"] == "r_topic:0/chatter" }
  end

  test "topics with no counterpart are attributes of their node" do
    cam = ros("/camera")["data"]["unmatched"]
    assert_equal [ "/camera/camera_info", "/camera/image_raw", "/parameter_events" ], cam.map { _1["name"] }.sort
    assert(cam.all? { _1["role"] == "publishes" })
    assert_equal "sensor_msgs/msg/Image", cam.find { _1["name"] == "/camera/image_raw" }["type"]
    sim = ros("/fmruby_talker_linux")["data"]["unmatched"]
    assert_equal [ [ "/chatter_back", "subscribes" ], [ "/cmd_vel_in", "subscribes" ] ], sim.map { [ _1["name"], _1["role"] ] }.sort
    refute node("r_topic:0/camera/image_raw")["data"]["matched"]
    # /rosout has a subscriber (the dashboard): matched, and an edge from every rclcpp node to it.
    assert node("r_topic:0/rosout")["data"]["matched"]
    refute ros("/talker")["data"]["unmatched"].any? { _1["name"] == "/rosout" }
    # /tf: the slam node publishes it and the navigator subscribes: not unmatched for slam.
    refute ros("/slam_toolbox")["data"]["unmatched"].to_a.any? { _1["name"] == "/tf" }
    # /parameter_events has publishers only.
    assert ros("/talker")["data"]["unmatched"].any? { _1["name"] == "/parameter_events" }
  end

  test "apps and objects are nested in their Asterism node" do
    assert_equal "a_node:fmruby-bbbbbb", node("a_app:fmruby-bbbbbb/sensors")["parent"]
    assert_equal "a_app:fmruby-bbbbbb/sensors", node("a_object:fmruby-bbbbbb/sensors/imu")["parent"]
    assert_equal 13, g["nodes"].count { _1["kind"] == "a_object" && _1["parent"] }
    refute g["edges"].any? { %w[has_app exposes].include?(_1["kind"]) }
    # The console has no apps of its own: a plain node, no children.
    refute g["nodes"].any? { _1["parent"] == "a_node:console" }
    # Sessions still carry the (compound) node, and the registry marks it.
    assert g["edges"].any? { _1["kind"] == "carries" && _1["target"] == "a_node:fmruby-aaaaaa" }
    assert_equal "unregistered", node("a_node:fmruby-aaaaaa")["data"]["registry"]
    assert_equal "registered", node("a_node:cruby")["data"]["registry"]
    assert_equal "zenohd-cloud", node("a_node:cruby")["data"]["via"]
    assert_equal "absent", node("reg:sparebot")["data"]["registry"]
  end

  test "routers and sessions are as they were" do
    routers = g["nodes"].select { _1["kind"] == "router" }.map { _1["label"] }.sort
    assert_equal [ "router zenohd-cloud", "router zenohd-home" ], routers
    assert_equal 1, g["edges"].count { _1["kind"] == "router_link" }
    assert_equal 17, g["nodes"].count { _1["kind"] == "session" }
    assert_equal 12, g["nodes"].count { _1["kind"] == "r_node" }
    assert_equal 18, g["nodes"].count { _1["kind"] == "r_topic" }
  end

  test "the same network gives the same graph; a new subscriber adds an edge, changes the topic" do
    assert_equal g, Bridge::Fixture.graph(INPUTS)
    zid = INPUTS["ros"].find { _1.end_with?("/NN/%/%/camera") }.split("/")[2]
    more = INPUTS.merge("ros" => INPUTS["ros"] + [ "@ros2_lv/0/#{zid}/0/99/MS/%/%/camera/%scan/sensor_msgs::msg::dds_::LaserScan_/RIHS01_0/::,10:,:,:,," ])
    d = Bridge::Graph.diff(g, Bridge::Fixture.graph(more))
    assert_includes d["add_edges"].map { _1["id"] }, "topic_link:#{ros('/lidar')['id']}->#{ros('/camera')['id']}"
    assert_includes d["change_nodes"].map { _1["id"] }, "r_topic:0/scan"
    assert_empty d["remove_nodes"]
  end
end
