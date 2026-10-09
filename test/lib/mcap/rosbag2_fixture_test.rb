require "test_helper"

# A file written by `ros2 bag record -s mcap --storage-preset-profile none`
# (ROS 2 Jazzy, rosbag2 with libmcap 1.3.1; demo data recorded for this
# test: /chatter from demo_nodes_cpp's talker, /cmd_vel and /imu from an
# rclpy node): what the reader makes of it, and that the console writes
# what rosbag2 writes (schemas byte for byte, the QoS metadata).
class Rosbag2FixtureTest < ActiveSupport::TestCase
  setup { @r = MCAP::Reader.new(file_fixture("rosbag2_jazzy.mcap").to_s) }
  teardown { @r.close }

  test "the summary, channels and counts" do
    assert @r.verify!
    info = @r.info
    assert_equal "ros2", info["profile"]
    assert_equal 114, info["messages"]
    assert_equal [ "" ], info["compression"]
    by = info["channels"].to_h { [ _1["topic"], _1 ] }
    assert_equal %w[/chatter /cmd_vel /imu], by.keys.sort
    assert_equal [ "geometry_msgs/msg/Twist", "ros2msg", "cdr", 19 ],
                 by["/cmd_vel"].values_at("schema", "schema_encoding", "message_encoding", "count")
    assert_equal %w[offered_qos_profiles topic_type_hash], by["/imu"]["metadata"].keys.sort
    assert_includes info["metadata"], "rosbag2"
  end

  test "the console's schemas are rosbag2's, byte for byte" do
    @r.schemas.each_value do |s|
      enc, text = Bag::MsgDefs.schema(s.name)
      assert_equal s.encoding, enc, s.name
      assert_equal s.data.b, text.b, s.name
    end
  end

  test "the console's QoS YAML is rosbag2's" do
    @r.channels.each_value do |c|
      yaml = c.metadata["offered_qos_profiles"]
      profiles = Bag::Qos.from_yaml(yaml)
      full = profiles.map { Bag::Qos.parse(Bag::Qos.token(_1)) }
      assert_equal yaml, Bag::Qos.yaml(full), c.topic
    end
    talker = @r.channels.values.find { _1.topic == "/chatter" }
    assert_equal 7, Bag::Qos.from_yaml(talker.metadata["offered_qos_profiles"]).first["depth"]
  end

  test "messages decode with the bundled types" do
    v = Bag::View.new(file_fixture("rosbag2_jazzy.mcap").to_s)
    cmd = v.channels.find { _1["topic"] == "/cmd_vel" }
    m = v.message(cmd["id"], v.start_ns + 1_000_000_000)
    assert_equal "cdr", m["format"]
    assert_match(/\Alinear \(/, m["text"])
    assert_kind_of Float, m["value"]["linear"]["x"]
    imu = v.channels.find { _1["topic"] == "/imu" }
    s = v.series(imu["id"], [ "linear_acceleration.z" ])
    assert_equal 93, s["used"]
    zs = s["v"]["linear_acceleration.z"]
    assert zs.all? { _1.between?(9.4, 10.2) }, zs.minmax.inspect
    chatter = v.channels.find { _1["topic"] == "/chatter" }
    assert_match(/Hello World: \d+/, v.message(chatter["id"], v.end_ns)["value"]["data"])
  ensure
    v&.close
  end
end
