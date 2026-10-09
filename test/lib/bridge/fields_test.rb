require "test_helper"

class Bridge::FieldsTest < ActiveSupport::TestCase
  F = Bridge::Fields

  test "paths parse into steps" do
    assert_equal %w[linear x], F.parse("linear.x")
    assert_equal [ "orientation_covariance", 4 ], F.parse("orientation_covariance[4]")
    assert_equal [ "poses", 0, "pose", "position", "x" ], F.parse("poses[0].pose.position.x")
    assert_equal [ 2 ], F.parse("[2]")
    assert_equal [], F.parse("")
    [ "a..b", "a.", ".a", "a[x]", "a[1", "a b", "a[1]x", "x" * 121 ].each { refute F.valid?(_1), _1 }
  end

  test "numbers are taken out of messages (symbol keys) and MessagePack values (string keys)" do
    twist = { linear: { x: 1.5, y: 0.0, z: 0.0 }, angular: { x: 0.0, y: 0.0, z: -0.5 } }
    assert_equal 1.5, F.extract(twist, "linear.x")
    assert_equal(-0.5, F.extract(twist, "angular.z"))
    assert_nil F.extract(twist, "linear.w")
    assert_nil F.extract(twist, "linear")
    imu = { "accel" => [ 0.1, 9.8, 0.2 ], "ok" => true, "name" => "imu", "bad" => Float::NAN }
    assert_equal 9.8, F.extract(imu, "accel[1]")
    assert_nil F.extract(imu, "accel[3]")
    assert_equal 1, F.extract(imu, "ok")
    assert_nil F.extract(imu, "name")
    assert_nil F.extract(imu, "bad")
    assert_equal 42, F.extract(42, "")
  end

  test "the numeric paths of a value, arrays bounded, sequences as [0]" do
    paths = F.paths({ header: { stamp: { sec: 1, nanosec: 2 }, frame_id: "" }, position: [], cov: Array.new(40, 0.0), flag: false })
    names = paths.map { _1["path"] }
    assert_equal [ "header.stamp.sec", "header.stamp.nanosec", "position[0]" ], names.first(3)
    assert_equal "sequence", paths[2]["kind"]
    assert_equal F::MAX_INDEX, names.count { _1.start_with?("cov[") }
    assert_equal "bool", paths.last["kind"]
    assert_equal [ { "path" => "", "kind" => "float" } ], F.paths(1.5)
    assert_operator F.paths({ "a" => Array.new(50) { { "b" => Array.new(16, 1) } } }).size, :<=, F::MAX_PATHS
  end

  test "the fields of a bundled ROS 2 type, from its definition" do
    Bridge::Types.setup
    paths = Bridge::Types.fields(Bridge::Types.ros("sensor_msgs/msg/Imu")).map { _1["path"] }
    assert_includes paths, "linear_acceleration.z"
    assert_includes paths, "orientation.w"
    assert_includes paths, "angular_velocity_covariance[8]"
    e = assert_raises(Bridge::Types::Unknown) { Bridge::Types.ros("shape_msgs/msg/Mesh") }
    assert_match(/not bundled/, e.message)
    assert_raises(Bridge::Types::Unknown) { Bridge::Types.ros("../../etc/msg/X") }
  end
end
