require "test_helper"
require "asterism"

class Bridge::LogsTest < ActiveSupport::TestCase
  ROSOUT = "0/rosout/rcl_interfaces::msg::dds_::Log_/RIHS01_e28c"

  setup do
    Bridge::Types.setup
    @log = Bridge::Types.ros("rcl_interfaces/msg/Log")
    @now = 100.0
    @logs = Bridge::Logs.new(clock: -> { @now }, wall: -> { 1_700_000_000_000 })
  end

  def rosout(level, name, text)
    @log.encode(stamp: { sec: 1_700_000_001, nanosec: 250_000_000 }, level: level, name: name, msg: text,
                file: "talker.cpp", function: "on_timer", line: 42)
  end

  test "a /rosout message decodes with the generated rcl_interfaces/msg/Log" do
    l = Bridge::Logs.line(ROSOUT, rosout(30, "talker", "Publishing: 'Hello World: 3'"), 1)
    assert_equal "WARN", l["level"]
    assert_equal 30, l["severity"]
    assert_equal "talker", l["name"]
    assert_equal "Publishing: 'Hello World: 3'", l["msg"]
    assert_equal [ "talker.cpp", 42, "on_timer" ], l.values_at("file", "line", "function")
    assert_equal 1_700_000_001_250, l["at"]
    assert_equal "ros", l["source"]
  end

  test "an Asterism log key: MessagePack { level, msg, time }" do
    l = Bridge::Logs.line("asterism/fmruby-aaaaaa/demo/log",
                          MessagePack.pack("level" => "error", "msg" => "motor stalled", "time" => 1_700_000_002.5), 1)
    assert_equal "ERROR", l["level"]
    assert_equal "fmruby-aaaaaa/demo", l["name"]
    assert_equal 1_700_000_002_500, l["at"]
    assert_equal "asterism", l["source"]
    l = Bridge::Logs.line("asterism/n/a/log", MessagePack.pack("just text"), 7)
    assert_equal [ "INFO", "just text", 7 ], l.values_at("level", "msg", "at")
    assert_equal 30, Bridge::Logs.severity(:warning)
    assert_equal 40, Bridge::Logs.severity(40)
  end

  test "what does not decode is counted, not shown" do
    @logs.record(ROSOUT, "\x00\x01\x00\x00".b)
    @logs.record(ROSOUT, rosout(20, "listener", "I heard"))
    lines = @logs.drain
    assert_equal [ "I heard" ], lines.map { _1["msg"] }
    assert_equal 1, @logs.errors
  end

  test "bounded: PENDING between drains, PER_SECOND lines a second" do
    (Bridge::Logs::PENDING + 10).times { @logs.record(ROSOUT, rosout(20, "spam", "x")) }
    assert_equal 10, @logs.dropped
    assert_equal Bridge::Logs::PER_SECOND, @logs.drain.size
    assert_equal 10 + Bridge::Logs::PENDING - Bridge::Logs::PER_SECOND, @logs.dropped
    @logs.record(ROSOUT, rosout(20, "spam", "x"))
    assert_empty @logs.drain, "the same second"
    @now += 1
    @logs.record(ROSOUT, rosout(20, "spam", "x"))
    assert_equal 1, @logs.drain.size
  end
end
