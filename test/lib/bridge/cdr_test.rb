require "test_helper"

# One-line previews of CDR messages (Bridge::Cdr, through Bridge::Payload).
class Bridge::CdrTest < ActiveSupport::TestCase
  LE = "\x00\x01\x00\x00".b

  def str(s, pos)
    pad = (4 - (pos % 4)) % 4
    ("\x00".b * pad) + [ s.bytesize + 1 ].pack("V") + s.b + "\x00".b
  end

  def show(bytes, type)
    Bridge::Payload.describe(bytes, type: type)["text"]
  end

  test "numbers and strings of std_msgs" do
    assert_equal "-42", show(LE + [ -42 ].pack("l<"), "std_msgs/msg/Int32")
    assert_equal "3.25", show(LE + [ 3.25 ].pack("E"), "std_msgs/msg/Float64")
    assert_equal "0.5", show(LE + [ 0.5 ].pack("e"), "std_msgs/msg/Float32")
    assert_equal "true", show(LE + "\x01".b, "std_msgs/msg/Bool")
    assert_equal "18446744073709551615", show(LE + [ 2**64 - 1 ].pack("Q<"), "std_msgs/msg/UInt64")
    assert_equal '"Hello World: 391"', show(LE + str("Hello World: 391", 0), "std_msgs/msg/String")
    # Big endian (CDR_BE, which rmw_zenoh does not send) is read by Cdr too.
    assert_equal "7", Bridge::Cdr.describe("\x00\x00\x00\x00".b + [ 7 ].pack("l>"), "std_msgs/msg/Int32")
  end

  test "geometry: Twist, Vector3, Quaternion" do
    twist = LE + [ 0.2, 0, 0, 0, 0, 0.35 ].pack("E*")
    assert_equal "linear (0.2, 0, 0) angular (0, 0, 0.35)", show(twist, "geometry_msgs/msg/Twist")
    assert_equal "(1, 2, 3)", show(LE + [ 1, 2, 3 ].pack("E*"), "geometry_msgs/msg/Vector3")
    assert_equal "(0, 0, 0, 1)", show(LE + [ 0, 0, 0, 1 ].pack("E*"), "geometry_msgs/msg/Quaternion")
  end

  test "a log line from /rosout" do
    b = LE + [ 1_791_590_400, 5 ].pack("l<V") + [ 20 ].pack("C")
    b += str("navigator", b.bytesize - 4)
    b += str("goal reached", b.bytesize - 4)
    b += str("nav.cpp", b.bytesize - 4) + str("run", 0) + [ 12 ].pack("V")
    assert_equal "[INFO] navigator: goal reached", show(b, "rcl_interfaces/msg/Log")
  end

  test "messages with a header show their stamp and frame" do
    b = LE + [ 1_791_590_399, 950_000_000 ].pack("l<V")
    b += str("odom", b.bytesize - 4) + ("\x00".b * 600)
    assert_equal 'stamp 1791590399.950, frame_id "odom"', show(b, "nav_msgs/msg/Odometry")
  end

  test "what does not read cleanly falls back to a string or hex" do
    assert_match(/\ACDR 00 01 00 00/, show(LE + "\x01\x02".b, "std_msgs/msg/Float64"))
    # A truncated header (the preview keeps the first bytes only).
    assert_match(/\ACDR /, show(LE + [ 1, 2 ].pack("l<V") + [ 500 ].pack("V") + "ab".b, "nav_msgs/msg/Odometry"))
    # No type: a string message is still read as one (as V1 did).
    assert_equal '"hi" (CDR string)', show(LE + str("hi", 0), nil)
    assert_match(/\ACDR /, show(LE + "\x01\x02\x03".b, "some_msgs/msg/Unknown"))
  end

  test "the type from a data key" do
    key = "0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_00"
    twist = LE + [ 1, 0, 0, 0, 0, 0 ].pack("E*")
    assert_equal "linear (1, 0, 0) angular (0, 0, 0)", Bridge::Payload.describe(twist, key: key)["text"]
  end
end
