require "test_helper"

# The pieces between MCAP and the console: message definitions, QoS,
# copying, repairing, and the timeline's view of a file.
class BagTest < ActiveSupport::TestCase
  T0 = 1_791_500_000_000_000_000

  def tmp(name) = Rails.root.join("tmp", "bag-test-#{Process.pid}-#{name}").to_s

  teardown { Dir.glob(Rails.root.join("tmp", "bag-test-#{Process.pid}-*")).each { FileUtils.rm_f(_1) } }

  test "message definitions: dependencies sorted, depth first, each once; an unknown type" do
    text = Bag::MsgDefs.full_text("nav_msgs/msg/Odometry")
    assert_equal %w[geometry_msgs/PoseWithCovariance geometry_msgs/Pose geometry_msgs/Point geometry_msgs/Quaternion
                    geometry_msgs/TwistWithCovariance geometry_msgs/Twist geometry_msgs/Vector3 std_msgs/Header
                    builtin_interfaces/Time], text.scan(/^MSG: (.*)$/).flatten
    assert_includes text, "\n#{'=' * 80}\nMSG: geometry_msgs/Pose\n"
    assert_equal [ "unknown", "" ], Bag::MsgDefs.schema("shape_msgs/msg/Mesh")
    assert_equal [ "unknown", "" ], Bag::MsgDefs.schema("../../etc/passwd")
    assert_equal [ "geometry_msgs/Vector3" ], Bag::MsgDefs.dependencies("Vector3 linear # x\nint32 A=1\nstring<=5 s\n", "geometry_msgs")
  end

  test "QoS from rmw_zenoh's token part" do
    assert_equal({ "history" => "keep_last", "depth" => 10, "reliability" => "reliable", "durability" => "volatile",
                   "deadline" => Bag::Qos::INFINITE, "lifespan" => Bag::Qos::INFINITE, "liveliness" => "automatic",
                   "liveliness_lease_duration" => Bag::Qos::INFINITE }, Bag::Qos.parse("::,10:,:,:,,"))
    q = Bag::Qos.parse("2:1:,5:1,500:,:,,")
    assert_equal [ "best_effort", "transient_local", 5, [ 1, 500 ] ], q.values_at("reliability", "durability", "depth", "deadline")
    assert_equal "2:1:,5:,:,:,,", Bag::Qos.token(q)
    yaml = Bag::Qos.yaml([ q, Bag::Qos.parse(nil) ])
    assert_equal 2, yaml.scan(/^- history/).size
    assert_equal [ "best_effort", "reliable" ], Bag::Qos.from_yaml(yaml).map { _1["reliability"] }
  end

  def write_mixed(path, finish: true)
    f = File.open(path, "wb")
    w = MCAP::Writer.new(f, profile: "ros2", chunk_size: 300)
    s = w.add_schema(name: "std_msgs/msg/String", encoding: "ros2msg", data: "string data\n")
    a = w.add_channel(topic: "/chatter", message_encoding: "cdr", schema_id: s)
    k = w.add_channel(topic: "demo/imu", message_encoding: "msgpack", schema_id: w.add_schema(name: "asterism/msgpack", encoding: "", data: ""))
    g = w.add_channel(topic: "/asterism/graph", message_encoding: "json",
                      schema_id: w.add_schema(name: "asterism/graph", encoding: "jsonschema", data: "{}"))
    graph = { "nodes" => [ { "id" => "r_node:a/0", "kind" => "r_node", "label" => "/talker" } ], "edges" => [] }
    w.add_message(channel_id: g, log_time: T0, data: JSON.generate("kind" => "snapshot", "version" => 1, "graph" => graph))
    10.times do |i|
      text = "hi #{i}"
      w.add_message(channel_id: a, log_time: T0 + (i + 1) * 100_000_000,
                    data: "\x00\x01\x00\x00".b + [ text.bytesize + 1 ].pack("V") + text.b + "\x00".b)
      w.add_message(channel_id: k, log_time: T0 + (i + 1) * 100_000_000 + 1, data: MessagePack.pack("x" => i, "y" => i * 0.5))
    end
    add = { "add_nodes" => [ { "id" => "r_node:b/0", "kind" => "r_node", "label" => "/listener" } ], "remove_nodes" => [],
            "change_nodes" => [], "add_edges" => [], "remove_edges" => [], "change_edges" => [] }
    w.add_message(channel_id: g, log_time: T0 + 400_000_000, data: JSON.generate("kind" => "diff", "version" => 2, "diff" => add))
    gone = add.merge("add_nodes" => [], "remove_nodes" => [ "r_node:b/0" ])
    w.add_message(channel_id: g, log_time: T0 + 800_000_000, data: JSON.generate("kind" => "diff", "version" => 3, "diff" => gone))
    w.flush
    w.finish if finish
    f.close
  end

  test "the view: channels by kind, ticks, the message at a time, series, the graph at a time" do
    write_mixed(path = tmp("mixed.mcap"))
    v = Bag::View.new(path)
    assert_equal %w[ros key graph], v.channels.map { _1["kind"] }
    t = v.ticks(10)
    assert_equal [ 10, 10, 3 ], t["channels"].values_at(1, 2, 3).map(&:sum)
    m = v.message(1, T0 + 350_000_000)
    assert_equal [ 2, "\"hi 2\"", T0 + 300_000_000, T0 + 400_000_000 ],
                 [ m["index"], m["text"], m["log_time"], m["next"] ]
    assert_equal({ "data" => "hi 2" }, m["value"])
    assert_equal({ "x" => 0, "y" => 0.0 }, v.message(2, 0)["value"]) # before the first: the first
    s = v.series(2, [ "y", "x" ])
    assert_equal [ 0.0, 0.5, 1.0 ], s["v"]["y"].first(3)
    assert_equal 10, s["used"]
    assert_equal [ "x", "y" ], v.fields(2).map { _1["path"] }
    assert_equal [ "/talker" ], v.graph_at(T0 + 100)["graph"]["nodes"].map { _1["label"] }
    assert_equal [ "/listener", "/talker" ], v.graph_at(T0 + 500_000_000)["graph"]["nodes"].map { _1["label"] }.sort
    assert_equal [ "/talker" ], v.graph_at(T0 + 900_000_000)["graph"]["nodes"].map { _1["label"] }
    ch = v.graph_changes
    assert_equal [ [], [ "r_node /listener" ], [] ], ch.map { _1["added"] }
    assert_equal [ [], [], [ "r_node /listener" ] ], ch.map { _1["removed"] }
    assert_raises(ArgumentError) { v.series(2, [ "a..b" ]) }
  ensure
    v&.close
  end

  test "copy: only the ROS 2 topics; repair: a file the bridge never finished" do
    write_mixed(src = tmp("src.mcap"))
    File.open(out = tmp("ros2.mcap"), "wb") { |f| assert_equal 10, Bag::Copy.ros2_only(src, f) }
    r = MCAP::Reader.new(out)
    assert r.verify!
    assert_equal [ "/chatter" ], r.info["channels"].map { _1["topic"] }
    r.close
    write_mixed(broken = tmp("broken.mcap"), finish: false)
    refute MCAP::Reader.new(broken).summary?
    n = Bag::Repair.call(broken)
    assert_equal 23, n
    r = MCAP::Reader.new(broken)
    assert r.summary? && r.verify!
    assert_equal 23, r.info["messages"]
  ensure
    r&.close
  end
end
