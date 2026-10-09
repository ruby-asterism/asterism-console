require "test_helper"

# Topic rates (Bridge::Rates) with a clock the test moves.
class Bridge::RatesTest < ActiveSupport::TestCase
  KEY = "0/chatter/std_msgs::msg::dds_::String_/RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18"

  setup do
    @now = 1000.0
    @rates = Bridge::Rates.new(clock: -> { @now }, wall: -> { (@now * 1000).round })
  end

  def cdr_string(text)
    "\x00\x01\x00\x00".b + [ text.bytesize + 1 ].pack("V") + text.b + "\x00".b
  end

  def feed(key, hz:, seconds:, bytes: cdr_string("hello"))
    (seconds * hz).round.times do
      @rates.record(key, bytes)
      @now += 1.0 / hz
    end
  end

  test "the topic of a data key" do
    assert_equal [ "r_topic:0/chatter", "std_msgs/msg/String" ], Bridge::Rates.topic_of(KEY)
    assert_equal "r_topic:3/ns/camera/image_raw",
                 Bridge::Rates.topic_of("3/ns/camera/image_raw/sensor_msgs::msg::dds_::Image_/RIHS01_00")[0]
    assert_nil Bridge::Rates.topic_of("asterism/fmruby-aaaaaa/demo/screen")
    assert_nil Bridge::Rates.topic_of("fmrb/test/out")
    assert_nil Bridge::Rates.topic_of("0/chatter")
  end

  test "rate and bandwidth over the window, the last message and its preview" do
    feed(KEY, hz: 10, seconds: 3)
    r = @rates.snapshot["r_topic:0/chatter"]
    assert_in_delta 10.0, r["hz"], 0.5
    assert_in_delta 10.0 * cdr_string("hello").bytesize, r["bps"], 10
    assert_equal 30, r["count"]
    assert_equal cdr_string("hello").bytesize, r["size"]
    assert_equal "cdr", r["format"]
    assert_equal '"hello"', r["text"]
    assert_equal "std_msgs/msg/String", r["type"]
    assert_operator r["at"], :<=, (@now * 1000).round
  end

  test "the window slides: a topic that stops goes to 0 Hz, one that slows follows" do
    feed(KEY, hz: 20, seconds: 6)
    assert_in_delta 20.0, @rates.snapshot(full: true)["r_topic:0/chatter"]["hz"], 1.0
    feed(KEY, hz: 2, seconds: 6)
    assert_in_delta 2.0, @rates.snapshot(full: true)["r_topic:0/chatter"]["hz"], 0.5
    @now += Bridge::Rates::WINDOW + 1
    r = @rates.snapshot(full: true)["r_topic:0/chatter"]
    assert_equal 0.0, r["hz"]
    assert_equal 0, r["bps"]
    assert_equal 132, r["count"], "the count and the last message stay"
  end

  test "several publishers on one topic add up" do
    other = KEY.sub("RIHS01_df66", "RIHS01_aa66") # the same topic seen with another hash: still one topic
    10.times do
      @rates.record(KEY, cdr_string("a"))
      @rates.record(other, cdr_string("b"))
      @now += 0.2
    end
    @now += 0.1
    assert_equal 1, @rates.size
    assert_in_delta 10.0, @rates.snapshot["r_topic:0/chatter"]["hz"], 1.0
  end

  test "nothing until half a second has been seen" do
    @rates.record(KEY, cdr_string("x"))
    assert_nil @rates.snapshot["r_topic:0/chatter"]["hz"]
  end

  test "a snapshot holds what changed since the last one" do
    feed(KEY, hz: 5, seconds: 2)
    assert_equal [ "r_topic:0/chatter" ], @rates.snapshot.keys
    assert_empty @rates.snapshot, "nothing new, the same rate"
    assert_equal [ "r_topic:0/chatter" ], @rates.snapshot(full: true).keys
    feed(KEY, hz: 5, seconds: 1)
    assert_equal [ "r_topic:0/chatter" ], @rates.snapshot.keys
  end

  test "bounded: topics, and the bytes kept of the last message" do
    big = "\x00\x01\x00\x00".b + ("\xff".b * 100_000)
    @rates.record("0/camera/image_raw/sensor_msgs::msg::dds_::Image_/RIHS01_0", big)
    e = @rates.instance_variable_get(:@topics)["r_topic:0/camera/image_raw"]
    assert_equal Bridge::Rates::PREVIEW_BYTES, e.last.bytesize
    assert_equal big.bytesize, e.size
    (Bridge::Rates::MAX_TOPICS + 5).times { |i| @rates.record("0/t#{i}/std_msgs::msg::dds_::Empty_/RIHS01_0", "x") }
    assert_equal Bridge::Rates::MAX_TOPICS, @rates.size
    assert_equal 6, @rates.dropped
    refute @rates.record("not/a/ros/key", "x")
  end

  test "keep_if, clear and covered?" do
    @rates.record(KEY, "x")
    @rates.record("1/other/std_msgs::msg::dds_::Empty_/RIHS01_0", "x")
    assert Bridge::Rates.covered?("r_topic:0/chatter", [ "0/**" ])
    assert Bridge::Rates.covered?("r_topic:0/chatter", [ "0/chatter/**" ])
    refute Bridge::Rates.covered?("r_topic:0/chatter", [ "1/**", "0/other/**" ])
    @rates.keep_if { Bridge::Rates.covered?(_1, [ "0/**" ]) }
    assert_equal 1, @rates.size
    @rates.clear
    assert_equal 0, @rates.size
  end

  test "total bandwidth" do
    feed(KEY, hz: 10, seconds: 2, bytes: "\x00\x01\x00\x00".b + ("x" * 996))
    assert_in_delta 10_000, @rates.total_bps, 600
  end
end
