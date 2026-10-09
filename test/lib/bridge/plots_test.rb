require "test_helper"
require "asterism"

class Bridge::PlotsTest < ActiveSupport::TestCase
  setup do
    @now = 1000.0
    @wall = 5_000_000
    @plots = Bridge::Plots.new(clock: -> { @now }, wall: -> { @wall })
    Bridge::Types.setup
    @twist = Bridge::Types.ros("geometry_msgs/msg/Twist")
    @plots.set("r_topic:0/cmd_vel", decoder: ->(b) { @twist.decode(b).to_h }, fields: [ "linear.x", "angular.z" ])
  end

  def msg(x, z)
    @twist.encode(linear: { x: x }, angular: { z: z })
  end

  test "at most RATE messages a second are kept and decoded" do
    # 1 kHz for one second.
    1000.times do |i|
      @now = 1000.0 + i / 1000.0
      @wall += 1
      @plots.record("r_topic:0/cmd_vel", msg(i.to_f, -i.to_f))
    end
    points, = @plots.drain
    p = points["r_topic:0/cmd_vel"]
    assert_equal Bridge::Plots::RATE, p["t"].size
    assert_equal 1000, p["received"]
    assert_equal Bridge::Plots::RATE, p["kept"]
    assert_equal p["t"].size, p["v"]["linear.x"].size
    assert_equal 0.0, p["v"]["linear.x"].first
    assert_equal(-p["v"]["linear.x"].last, p["v"]["angular.z"].last)
  end

  test "pending is bounded between drains" do
    500.times do |i|
      @now += 0.05
      @plots.record("r_topic:0/cmd_vel", msg(1.0, 2.0))
    end
    points, = @plots.drain
    assert_equal Bridge::Plots::PENDING, points["r_topic:0/cmd_vel"]["t"].size
    assert_empty @plots.drain.first, "nothing new"
  end

  test "a message that does not decode is counted, the rest go on" do
    @plots.record("r_topic:0/cmd_vel", "\x00\x01\x00\x00\x01".b)
    @now += 0.1
    @plots.record("r_topic:0/cmd_vel", msg(3.0, 4.0))
    points, = @plots.drain
    assert_equal 1, points["r_topic:0/cmd_vel"]["errors"]
    assert_equal [ 3.0 ], points["r_topic:0/cmd_vel"]["v"]["linear.x"]
  end

  test "the fields a message has are reported when they change" do
    @plots.record("r_topic:0/cmd_vel", msg(1.0, 2.0))
    _, observed = @plots.drain
    assert_includes observed["r_topic:0/cmd_vel"].map { _1["path"] }, "angular.z"
    @now += 5
    @plots.record("r_topic:0/cmd_vel", msg(1.0, 2.0))
    _, observed = @plots.drain
    assert_empty observed
  end

  test "fields change in place; targets are bounded; unknown targets are ignored" do
    @plots.wanted("r_topic:0/cmd_vel", [ "linear.y", "bad path" ])
    assert_equal [ "linear.y" ], @plots.fields("r_topic:0/cmd_vel")
    refute @plots.record("r_topic:0/other", "x")
    (Bridge::Plots::MAX_TARGETS - 1).times { |i| assert @plots.set("key:k#{i}", decoder: ->(b) { b }, fields: []) }
    refute @plots.set("key:one-more", decoder: ->(b) { b }, fields: [])
  end

  test "Asterism keys: MessagePack Hashes and numbers" do
    dec = Bridge::Plots.msgpack_decoder
    @plots.set("key:demo/imu", decoder: dec, fields: [ "accel[2]", "temp" ])
    @plots.record("key:demo/imu", MessagePack.pack("accel" => [ 0.1, 0.2, 9.8 ], "temp" => 31))
    points, = @plots.drain
    assert_equal [ 9.8 ], points["key:demo/imu"]["v"]["accel[2]"]
    assert_equal [ 31 ], points["key:demo/imu"]["v"]["temp"]
    assert_equal 23.5, dec.call("23.5")
    assert_equal 7, dec.call(MessagePack.pack(7))
  end
end
