require "test_helper"

# The MCAP writer and reader on their own: round trips, the summary and
# the CRCs, files without a summary, cut-off files, unknown records.
class MCAPTest < ActiveSupport::TestCase
  T0 = 1_791_500_000_000_000_000

  def write(chunk_size: MCAP::Writer::DEFAULT_CHUNK_SIZE, finish: true)
    io = StringIO.new("".b)
    w = MCAP::Writer.new(io, profile: "ros2", chunk_size: chunk_size)
    s = w.add_schema(name: "std_msgs/msg/String", encoding: "ros2msg", data: "string data\n")
    a = w.add_channel(topic: "/chatter", message_encoding: "cdr", schema_id: s, metadata: { "k" => "v" })
    k = w.add_schema(name: "asterism/msgpack", encoding: "", data: "")
    b = w.add_channel(topic: "demo/imu", message_encoding: "msgpack", schema_id: k)
    50.times do |i|
      w.add_message(channel_id: a, log_time: T0 + i * 1_000_000, publish_time: T0 + i * 1_000_000 - 5, sequence: i,
                    data: "cdr-#{i}".b)
      w.add_message(channel_id: b, log_time: T0 + i * 1_000_000 + 500, data: [ i ].pack("C")) if i.even?
    end
    w.add_metadata("note", "who" => "test")
    w.finish if finish
    [ io.string, w ]
  end

  def reader(bytes)
    MCAP::Reader.new(StringIO.new(bytes))
  end

  test "round trip: header, schemas, channels, messages, metadata, statistics" do
    bytes, = write
    assert bytes.start_with?(MCAP::MAGIC) && bytes.end_with?(MCAP::MAGIC)
    r = reader(bytes)
    assert r.verify!
    assert_equal "ros2", r.header.profile
    assert r.summary?
    info = r.info
    assert_equal 75, info["messages"]
    assert_equal T0, info["start"]
    assert_equal T0 + 49_000_000, info["end"]
    assert_equal [ "" ], info["compression"]
    assert_equal [ "note" ], info["metadata"]
    chatter, imu = info["channels"]
    assert_equal [ "/chatter", "cdr", "std_msgs/msg/String", 50, { "k" => "v" } ],
                 chatter.values_at("topic", "message_encoding", "schema", "count", "metadata")
    assert_equal [ "demo/imu", "msgpack", "asterism/msgpack", "", 25 ],
                 imu.values_at("topic", "message_encoding", "schema", "schema_encoding", "count")
    msgs = r.each_message.to_a
    assert_equal 75, msgs.size
    m, ch, schema = msgs.first
    assert_equal [ 1, 0, T0, T0 - 5, "cdr-0" ], [ m.channel_id, m.sequence, m.log_time, m.publish_time, m.data ]
    assert_equal "/chatter", ch.topic
    assert_equal "string data\n", schema.data
    assert_equal({ "note" => { "who" => "test" } }, r.metadata)
  end

  test "chunks: several, each with its message indexes; the index finds every message" do
    bytes, w = write(chunk_size: 256)
    r = reader(bytes)
    assert r.verify!
    assert_operator r.summary[:chunk_indexes].size, :>, 5
    assert_equal r.summary[:chunk_indexes].size, r.info["chunks"]
    idx = r.index
    assert_equal [ 50, 25 ], [ idx[1].size, idx[2].size ]
    assert_equal idx[1].map(&:first), idx[1].map(&:first).sort
    t, ref = idx[1][17]
    m = r.message_at(ref)
    assert_equal [ T0 + 17_000_000, "cdr-17" ], [ t, m.data ]
    assert_equal 75, w.message_count
  end

  test "the CRCs are checked" do
    bytes, = write
    bad = bytes.dup
    at = bad.index("cdr-3")
    bad.setbyte(at, bad.getbyte(at) ^ 0xff)
    assert_raises(MCAP::FormatError) { reader(bad).verify! }
    bad = bytes.dup
    at = bad.bytesize - 8 - 29 - 1 # the last byte of the summary offsets
    bad.setbyte(at, bad.getbyte(at) ^ 0xff)
    assert_raises(MCAP::FormatError) { reader(bad).summary }
  end

  test "a file without a summary (never finished) reads by scanning; cut off mid-record too" do
    io = StringIO.new("".b)
    w = MCAP::Writer.new(io, chunk_size: 200)
    c = w.add_channel(topic: "k", message_encoding: "json")
    20.times { |i| w.add_message(channel_id: c, log_time: T0 + i, data: "{\"i\":#{i}}") }
    w.flush
    whole = io.string.dup
    r = reader(whole)
    refute r.summary?
    assert_equal 20, r.info["messages"]
    assert_equal 20, r.each_message.count
    assert_equal 20, r.index[1].size
    # Cut in the middle of the last chunk: the chunks before it read.
    cut = whole.byteslice(0, whole.index("{\"i\":19}") + 3)
    r = reader(cut)
    n = r.each_message.count
    assert r.truncated?
    assert_operator n, :>, 0
    assert_operator n, :<, 20
    assert_equal n, r.info["messages"]
  end

  test "unknown and private records in the data section are skipped" do
    c = MCAP::Codec
    bytes = MCAP::MAGIC + c.record(MCAP::HEADER, c.str("") + c.str("hand")) +
            c.record(0x80, "private".b) +
            c.record(MCAP::CHANNEL, c.u16(1) + c.u16(0) + c.str("k") + c.str("json") + c.map_ss({})) +
            c.record(0x7e, "a future record".b) +
            c.record(MCAP::MESSAGE, c.u16(1) + c.u32(0) + c.u64(T0) + c.u64(T0) + "{}") +
            c.record(MCAP::DATA_END, c.u32(0)) +
            c.record(MCAP::FOOTER, c.u64(0) + c.u64(0) + c.u32(0)) + MCAP::MAGIC
    r = reader(bytes)
    refute r.summary?
    assert_equal [ [ "k", "{}" ] ], r.each_message.map { |m, ch, _| [ ch.topic, m.data ] }
    assert_equal 1, r.info["messages"]
  end

  test "the smallest file: header and footer" do
    io = StringIO.new("".b)
    MCAP::Writer.new(io).finish
    r = reader(io.string)
    assert r.verify!
    assert_equal 0, r.info["messages"]
    assert_nil r.info["start"]
    assert_empty r.each_message.to_a
  end

  test "not an MCAP file" do
    assert_raises(MCAP::FormatError) { reader("hello world, not a file at all".b) }
    assert_raises(MCAP::FormatError) { reader("\x89MCAP0\r\n".b + "\x02".b + "\x00" * 40) }
  end

  test "a compressed chunk: the summary and the index read, the messages raise UnsupportedCompression" do
    r = MCAP::Reader.new(file_fixture("rosbag2_jazzy_zstd.mcap").to_s)
    assert_equal [ "zstd" ], r.info["compression"]
    assert_equal 26, r.info["messages"]
    assert_equal 26, r.index.values.sum(&:size)
    e = assert_raises(MCAP::UnsupportedCompression) { r.message_at(r.index.values.first.first[1]) }
    assert_equal "zstd", e.compression
    assert_raises(MCAP::UnsupportedCompression) { r.each_message.first }
  end
end
