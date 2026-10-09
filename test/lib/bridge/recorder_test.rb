require "test_helper"
require "asterism"

# The recorder on its own: what it writes for ROS 2 samples, Asterism keys
# and the network structure, and its limits.
class Bridge::RecorderTest < ActiveSupport::TestCase
  KEY = "0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_9c45bf16fe0983d80e3cfe750d6835843d265a9a6c46bd2e609fcddde6fb8d2a"
  Stamp = Struct.new(:time) do
    def to_time = time
  end

  setup do
    @dir = Rails.root.join("tmp", "recorder-test-#{Process.pid}")
    FileUtils.mkdir_p(@dir)
    @now = 0.0
    @wall = 1_791_500_000_000_000_000
    @twist = Bridge::Types.ros("geometry_msgs/msg/Twist")
  end

  teardown { FileUtils.rm_rf(@dir) }

  def recorder(**opts)
    Bridge::Recorder.new(id: 1, path: @dir.join("r.mcap"), max_bytes: 1024 * 1024, max_seconds: 60,
                         clock: -> { @now }, wall_ns: -> { @wall += 1_000_000 }, **opts) { |_tid| [ Bag::Qos.parse("::,7:,:,:,,") ] }
  end

  def ros_sample(x, seq)
    att = Asterism::ROS::Attachment.new(seq, 1_791_400_000_000_000_000 + seq, "g" * 16).encode
    Asterism::Zenoh::Sample.new(key: KEY, payload: @twist.encode(linear: { x: x }), attachment: att)
  end

  test "ROS 2 samples as rosbag2 writes them; Asterism keys; the structure" do
    rec = recorder(structure: true).open
    graph = { "nodes" => [ { "id" => "a", "kind" => "r_node", "label" => "/a" } ], "edges" => [] }
    rec.graph(5, graph)
    3.times { |i| assert rec.ros(ros_sample(0.1 * i, i + 1)) }
    stamp = Stamp.new(Time.at(1_791_450_000, 250, :usec))
    assert rec.key("demo/**", Asterism::Zenoh::Sample.new(key: "demo/imu", payload: MessagePack.pack("t" => 1), timestamp: stamp))
    rec.graph(6, graph, { "add_nodes" => [], "remove_nodes" => [ "a" ] })
    refute rec.ros(Asterism::Zenoh::Sample.new(key: "not/a/ros/key", payload: "x"))
    p = rec.finish("stopped")
    assert_equal 6, p["messages"]
    assert_equal({ "/asterism/graph" => 2, "/cmd_vel" => 3, "demo/imu" => 1 }, p["channel_counts"])
    r = MCAP::Reader.new(@dir.join("r.mcap").to_s)
    assert r.verify!
    by = r.info["channels"].to_h { [ _1["topic"], _1 ] }
    cmd = by["/cmd_vel"]
    assert_equal [ "cdr", "geometry_msgs/msg/Twist", "ros2msg" ], cmd.values_at("message_encoding", "schema", "schema_encoding")
    assert_equal KEY.split("/").last, cmd["metadata"]["topic_type_hash"]
    assert_equal "0", cmd["metadata"]["ros_domain"]
    assert_match(/\A- history: keep_last\n  depth: 7\n/, cmd["metadata"]["offered_qos_profiles"])
    assert_equal [ "msgpack", "asterism/msgpack", "" ], by["demo/imu"].values_at("message_encoding", "schema", "schema_encoding")
    assert_equal "demo/**", by["demo/imu"]["metadata"]["asterism_key_expr"]
    assert_equal [ "json", "asterism/graph", "jsonschema" ], by["/asterism/graph"].values_at("message_encoding", "schema", "schema_encoding")
    msgs = r.each_message.map { |m, ch, _| [ ch.topic, m ] }
    first_ros = msgs.find { _1[0] == "/cmd_vel" }[1]
    assert_equal [ 1, 1_791_400_000_000_000_001 ], [ first_ros.sequence, first_ros.publish_time ]
    assert_operator first_ros.log_time, :>, first_ros.publish_time
    key_msg = msgs.find { _1[0] == "demo/imu" }[1]
    assert_equal 1_791_450_000_000_250_000, key_msg.publish_time
    kinds = msgs.select { _1[0] == "/asterism/graph" }.map { JSON.parse(_1[1].data)["kind"] }
    assert_equal %w[snapshot diff], kinds
    assert_equal({ x: 0.2, y: 0.0, z: 0.0 }, @twist.decode(msgs.select { _1[0] == "/cmd_vel" }.last[1].data).to_h[:linear])
  ensure
    r&.close
  end

  test "the size limit: the message that would pass it is not written, and the reason is told" do
    rec = Bridge::Recorder.new(id: 2, path: @dir.join("s.mcap"), max_bytes: 4000, max_seconds: 60).open
    n = 0
    n += 1 while rec.key("k", Asterism::Zenoh::Sample.new(key: "k", payload: "x" * 100)) && n < 1000
    assert_match(/size limit/, rec.limit_reached)
    rec.finish
    assert_operator File.size(@dir.join("s.mcap")), :<=, 4000 + 1200 # the limit and the summary
    assert_equal n, MCAP::Reader.new(@dir.join("s.mcap").to_s).info["messages"]
  end

  test "the time limit" do
    rec = recorder.open
    assert_nil rec.limit_reached
    @now = 61.0
    assert_match(/time limit \(60 s\)/, rec.limit_reached)
    refute rec.ros(ros_sample(1.0, 1))
  end

  test "chunks are written about once a second, so a crash keeps what came before" do
    rec = recorder.open
    rec.ros(ros_sample(1.0, 1))
    @now = 1.5
    rec.tick
    r = MCAP::Reader.new(@dir.join("r.mcap").to_s)
    refute r.summary?
    assert_equal 1, r.info["messages"]
  end
end
