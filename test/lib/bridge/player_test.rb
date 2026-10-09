require "test_helper"
require "asterism"

# Playback to the network with a stand-in session: what goes on the wire.
class Bridge::PlayerTest < ActiveSupport::TestCase
  class FakeSession
    Token = Struct.new(:key, :closed) do
      def close = (self.closed = true)
    end

    attr_reader :puts, :tokens

    def initialize
      @puts = []
      @tokens = []
    end

    def zid = "abcdef0123456789"

    def liveliness(key)
      (@tokens << Token.new(key, false)).last
    end

    def put(key, payload, attachment: nil)
      @puts << [ key, payload, attachment, Process.clock_gettime(Process::CLOCK_MONOTONIC) ]
    end
  end

  setup do
    @dir = Rails.root.join("tmp", "player-test-#{Process.pid}")
    FileUtils.mkdir_p(@dir)
    @path = @dir.join("p.mcap").to_s
    twist = Bridge::Types.ros("geometry_msgs/msg/Twist")
    @payloads = 4.times.map { twist.encode(linear: { x: _1 * 0.5 }) }
    t0 = 1_791_500_000_000_000_000
    File.open(@path, "wb") do |f|
      w = MCAP::Writer.new(f, profile: "ros2")
      s = w.add_schema(name: "geometry_msgs/msg/Twist", encoding: "ros2msg", data: "")
      c = w.add_channel(topic: "/cmd_vel", message_encoding: "cdr", schema_id: s,
                        metadata: { "topic_type_hash" => "RIHS01_aa", "offered_qos_profiles" => Bag::Qos.yaml([ Bag::Qos.parse("::,5:,:,:,,") ]) })
      k = w.add_channel(topic: "demo/imu", message_encoding: "msgpack", schema_id: w.add_schema(name: "asterism/msgpack", encoding: "", data: ""))
      g = w.add_channel(topic: "/asterism/graph", message_encoding: "json", schema_id: w.add_schema(name: "asterism/graph", encoding: "jsonschema", data: "{}"))
      @payloads.each_with_index do |b, i|
        w.add_message(channel_id: c, log_time: t0 + i * 200_000_000, data: b)
        w.add_message(channel_id: k, log_time: t0 + i * 200_000_000 + 1, data: MessagePack.pack(i))
      end
      w.add_message(channel_id: g, log_time: t0, data: "{}")
      w.finish
    end
    @t0 = t0
    @session = FakeSession.new
    @asterism = []
  end

  teardown { FileUtils.rm_rf(@dir) }

  def player(**opts)
    Bridge::Player.new(playback_id: 1, path: @path, speed: 4.0, session: @session,
                       put: ->(k, b) { @asterism << [ k, b, Process.clock_gettime(Process::CLOCK_MONOTONIC) ] }, **opts)
  end

  test "ROS 2 with the console's own tokens and attachments, Asterism keys as they were, not the structure" do
    pl = player
    pl.define_singleton_method(:wait) { |s| sleep(s) if s.positive? && s < 1 } # no discovery pause in the test
    pl.run
    assert_nil pl.error
    assert_equal 8, pl.sent
    assert_equal({ "/asterism/graph" => "the network structure is not sent" }, pl.skipped)
    keys = @session.tokens.map(&:key)
    assert_includes keys, "@ros2_lv/0/abcdef0123456789/0/0/NN/%/%/asterism_console_playback"
    assert(keys.any? { _1.include?("/MP/%/%/asterism_console_playback/%cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_aa/::,5:,:,:,,") })
    assert @session.tokens.all?(&:closed), "the tokens are withdrawn after the playback"
    assert_equal [ "0/cmd_vel/geometry_msgs::msg::dds_::Twist_/RIHS01_aa" ], @session.puts.map(&:first).uniq
    assert_equal @payloads, @session.puts.map { _1[1] }
    atts = @session.puts.map { Asterism::ROS::Attachment.decode(_1[2]) }
    assert_equal [ 1, 2, 3, 4 ], atts.map(&:sequence)
    assert_equal 1, atts.map(&:gid).uniq.size
    assert_operator atts.first.stamp_ns, :>, @t0 # the time it is sent, not the recorded one
    assert_equal [ "demo/imu" ] * 4, @asterism.map(&:first)
    assert_equal [ 0, 1, 2, 3 ], @asterism.map { MessagePack.unpack(_1[1]) }
    # 600 ms of recording at 4x: about 150 ms.
    span = @session.puts.last[3] - @session.puts.first[3]
    assert_in_delta 0.15, span, 0.08
  end

  test "from a time, only some channels; stop" do
    pl = player(channel_ids: [ 2 ], start_ns: @t0 + 300_000_000)
    pl.define_singleton_method(:wait) { |_s| nil }
    pl.run
    assert_equal 2, pl.sent
    assert_empty @session.puts
    assert_equal [ 2, 3 ], @asterism.map { MessagePack.unpack(_1[1]) }
    pl = player(speed: 0.25)
    pl.stop
    pl.run
    assert_equal 0, pl.sent
  end
end
