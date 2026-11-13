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

  test "protocol 2 keys: the recorded encoding and attachment (sequence, and the sender's time when declared)" do
    path = @dir.join("p2.mcap").to_s
    t0 = @t0
    File.open(path, "wb") do |f|
      w = MCAP::Writer.new(f, profile: "ros2")
      meta = ->(decl, protocol = "2") do
        { "asterism_key_expr" => "asterism/linux/demo/**", "asterism_protocol" => protocol,
          "asterism_declaration" => JSON.generate(decl) }
      end
      imu = w.add_channel(topic: "asterism/linux/demo/imu", message_encoding: "msgpack",
                          schema_id: w.add_schema(name: "asterism/vector3", encoding: "", data: ""),
                          metadata: meta.({ "t" => 2, "ts" => true }))
      cam = w.add_channel(topic: "asterism/linux/demo/camera", message_encoding: "image/jpeg",
                          schema_id: w.add_schema(name: "asterism/image", encoding: "", data: ""),
                          metadata: meta.({ "t" => 4, "e" => 17 }))
      old = w.add_channel(topic: "asterism/linux/demo/old", message_encoding: "msgpack",
                          schema_id: w.add_schema(name: "asterism/msgpack", encoding: "", data: ""),
                          metadata: { "asterism_key_expr" => "asterism/linux/demo/**", "asterism_protocol" => "1" })
      w.add_message(channel_id: imu, log_time: t0, publish_time: 1_791_400_000_123_000_000, sequence: 41,
                    data: MessagePack.pack([ 1, 2, 3 ]))
      w.add_message(channel_id: cam, log_time: t0 + 1, publish_time: t0, sequence: 5, data: "\xFF\xD8jpeg".b)
      w.add_message(channel_id: old, log_time: t0 + 2, data: MessagePack.pack(1))
      w.finish
    end
    puts_seen = []
    pl = Bridge::Player.new(playback_id: 2, path: path, speed: 100.0, session: @session,
                            put: ->(k, b, **opts) { puts_seen << [ k, b, opts ] })
    pl.define_singleton_method(:wait) { |_s| nil }
    pl.run
    assert_nil pl.error
    assert_equal({}, pl.skipped, "a JPEG topic is sent too")
    assert_equal 3, pl.sent
    by = puts_seen.to_h { [ _1[0], _1 ] }
    imu = by["asterism/linux/demo/imu"]
    refute imu[2].key?(:encoding), "MessagePack goes without an encoding"
    assert_equal [ 41, 1_791_400_000_123 ], MessagePack.unpack(imu[2][:attachment])
    cam = by["asterism/linux/demo/camera"]
    assert_equal "image/jpeg", cam[2][:encoding]
    assert_equal [ 5 ], MessagePack.unpack(cam[2][:attachment]), "no ts declared: the number alone"
    assert_equal "\xFF\xD8jpeg".b, cam[1]
    assert_equal({}, by["asterism/linux/demo/old"][2], "a protocol 1 recording: as it was")
  end

  test "a shared place's channels go out with their sender's attachment" do
    path = @dir.join("p3.mcap").to_s
    key = "asterism/host/@shared/spectate/t1/state"
    t0 = @t0
    File.open(path, "wb") do |f|
      w = MCAP::Writer.new(f, profile: "ros2")
      sid = w.add_schema(name: "g/table", encoding: "", data: "")
      chan = lambda do |topic, from, decl|
        w.add_channel(topic: topic, message_encoding: "msgpack", schema_id: sid,
                      metadata: { "asterism_key_expr" => "asterism/*/@shared/**", "asterism_protocol" => "2",
                                  "asterism_declaration" => JSON.generate(decl), "asterism_from" => from }.compact)
      end
      games = chan.(key, "host/games", { "t" => "g/table" })
      room = chan.(key, "host/room01", { "t" => "g/table", "ts" => true })
      lobby = chan.("asterism/@shared/lobby", "pc/chat", { "t" => 7 })
      app = chan.("asterism/host/games/x", "host/games", { "t" => 1 }) # not a shared key: the app's own form
      w.add_message(channel_id: games, log_time: t0, publish_time: t0, sequence: 4, data: MessagePack.pack(1))
      w.add_message(channel_id: room, log_time: t0 + 1, publish_time: 1_791_440_000_500_000_000, sequence: 0, data: MessagePack.pack(2))
      w.add_message(channel_id: lobby, log_time: t0 + 2, publish_time: t0, sequence: 9, data: MessagePack.pack("hi"))
      w.add_message(channel_id: app, log_time: t0 + 3, publish_time: t0, sequence: 3, data: MessagePack.pack(3))
      w.finish
    end
    seen = []
    pl = Bridge::Player.new(playback_id: 3, path: path, speed: 100.0, session: @session,
                            put: ->(k, b, **opts) { seen << [ k, MessagePack.unpack(opts[:attachment]) ] })
    pl.define_singleton_method(:wait) { |_s| nil }
    pl.run
    assert_nil pl.error
    assert_equal [ [ key, [ 4, nil, "host/games" ] ], [ key, [ 0, 1_791_440_000_500, "host/room01" ] ],
                   [ "asterism/@shared/lobby", [ 9, nil, "pc/chat" ] ], [ "asterism/host/games/x", [ 3 ] ] ], seen
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
