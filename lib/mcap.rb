# MCAP (https://mcap.dev, format version 0): a container for timestamped
# messages of any encoding, the default storage of ROS 2's rosbag2 since
# Iron and what Foxglove reads. A pure-Ruby writer and reader, standard
# library only (Zlib for the CRC32s): MCAP::Writer, MCAP::Reader.
#
#   File.open("out.mcap", "wb") do |f|
#     w = MCAP::Writer.new(f, profile: "ros2")
#     s = w.add_schema(name: "std_msgs/msg/String", encoding: "ros2msg", data: "string data\n")
#     c = w.add_channel(topic: "/chatter", message_encoding: "cdr", schema_id: s)
#     w.add_message(channel_id: c, log_time: ns, publish_time: ns, data: cdr_bytes)
#     w.finish
#   end
#
#   r = MCAP::Reader.new("out.mcap")
#   r.info                      # channels, schemas, counts, start / end, compression
#   r.each_message { |m, channel, schema| ... }
#
# Compression: chunks are written uncompressed (the "" compression), and
# read when uncompressed. A chunk compressed with zstd or lz4 (neither is in
# Ruby's standard library) raises MCAP::UnsupportedCompression when its
# messages are read; the summary, the statistics and the message indexes
# (which are never compressed) still read, so such a file still lists its
# channels, counts and message times.
#
# Records (opcodes) written: Header, Schema, Channel, Message, Chunk,
# Message Index, Metadata, Data End, and in the summary Schema, Channel,
# Statistics, Chunk Index, Metadata Index and Summary Offset, then Footer.
# Read: all of those, plus Attachment and Attachment Index (kept as they
# are); unknown and private opcodes are skipped, as the specification asks.
module MCAP
  VERSION = "0.1.0"
  MAGIC = "\x89MCAP0\r\n".b

  # Record opcodes.
  HEADER = 0x01
  FOOTER = 0x02
  SCHEMA = 0x03
  CHANNEL = 0x04
  MESSAGE = 0x05
  CHUNK = 0x06
  MESSAGE_INDEX = 0x07
  CHUNK_INDEX = 0x08
  ATTACHMENT = 0x09
  ATTACHMENT_INDEX = 0x0a
  STATISTICS = 0x0b
  METADATA = 0x0c
  METADATA_INDEX = 0x0d
  SUMMARY_OFFSET = 0x0e
  DATA_END = 0x0f

  OPCODE_NAMES = {
    HEADER => "Header", FOOTER => "Footer", SCHEMA => "Schema", CHANNEL => "Channel", MESSAGE => "Message",
    CHUNK => "Chunk", MESSAGE_INDEX => "MessageIndex", CHUNK_INDEX => "ChunkIndex", ATTACHMENT => "Attachment",
    ATTACHMENT_INDEX => "AttachmentIndex", STATISTICS => "Statistics", METADATA => "Metadata",
    METADATA_INDEX => "MetadataIndex", SUMMARY_OFFSET => "SummaryOffset", DATA_END => "DataEnd"
  }.freeze

  class Error < StandardError; end

  # The bytes are not an MCAP file (or break its rules).
  class FormatError < Error; end

  # A chunk is compressed with an algorithm this library does not have.
  class UnsupportedCompression < Error
    attr_reader :compression

    def initialize(compression)
      @compression = compression
      super("unsupported compression #{compression.inspect} (only uncompressed chunks are read; " \
            "zstd and lz4 are not in Ruby's standard library)")
    end
  end

  Header = Struct.new(:profile, :library)
  Footer = Struct.new(:summary_start, :summary_offset_start, :summary_crc)
  Schema = Struct.new(:id, :name, :encoding, :data)
  Channel = Struct.new(:id, :schema_id, :topic, :message_encoding, :metadata)
  Message = Struct.new(:channel_id, :sequence, :log_time, :publish_time, :data)
  Chunk = Struct.new(:message_start_time, :message_end_time, :uncompressed_size, :uncompressed_crc,
                     :compression, :records)
  MessageIndex = Struct.new(:channel_id, :records) # records: [[log_time, offset], ...]
  ChunkIndex = Struct.new(:message_start_time, :message_end_time, :chunk_start_offset, :chunk_length,
                          :message_index_offsets, :message_index_length, :compression, :compressed_size,
                          :uncompressed_size)
  Attachment = Struct.new(:log_time, :create_time, :name, :media_type, :data, :crc)
  AttachmentIndex = Struct.new(:offset, :length, :log_time, :create_time, :data_size, :name, :media_type)
  Statistics = Struct.new(:message_count, :schema_count, :channel_count, :attachment_count, :metadata_count,
                          :chunk_count, :message_start_time, :message_end_time, :channel_message_counts)
  Metadata = Struct.new(:name, :metadata)
  MetadataIndex = Struct.new(:offset, :length, :name)
  SummaryOffset = Struct.new(:group_opcode, :group_start, :group_length)
  DataEnd = Struct.new(:data_section_crc)

  # Serialization of the field types (little endian; strings, arrays and
  # maps with a uint32 byte length; bytes with uint32 or uint64).
  module Codec
    module_function

    def u8(v) = [ v ].pack("C")
    def u16(v) = [ v ].pack("v")
    def u32(v) = [ v ].pack("V")
    def u64(v) = [ v ].pack("Q<")

    def str(s)
      b = s.to_s.b
      u32(b.bytesize) + b
    end

    def bytes32(b) = u32(b.bytesize) + b.b
    def bytes64(b) = u64(b.bytesize) + b.b

    # Map<string, string>, in the order given.
    def map_ss(h)
      body = h.map { |k, v| str(k.to_s) + str(v.to_s) }.join.b
      u32(body.bytesize) + body
    end

    # Map<uint16, uint64>
    def map_u16_u64(h)
      body = h.map { |k, v| u16(k) + u64(v) }.join.b
      u32(body.bytesize) + body
    end

    def record(op, body)
      u8(op) + u64(body.bytesize) + body
    end
  end

  # Reads the fields of one record's body; raises FormatError when they run
  # past its end.
  class Cursor
    attr_reader :pos

    def initialize(bytes, pos = 0, limit = bytes.bytesize)
      @b = bytes
      @pos = pos
      @limit = limit
    end

    def rest = @limit - @pos
    def eof? = @pos >= @limit

    def take(n)
      raise FormatError, "record too short (want #{n} bytes, #{rest} left)" if n.negative? || n > rest
      v = @b.byteslice(@pos, n)
      @pos += n
      v
    end

    def u8 = take(1).unpack1("C")
    def u16 = take(2).unpack1("v")
    def u32 = take(4).unpack1("V")
    def u64 = take(8).unpack1("Q<")

    def str
      s = take(u32).force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : s.b
    end

    def bytes32 = take(u32)
    def bytes64 = take(u64)

    def map_ss
      n = u32_peek_len
      sub = Cursor.new(@b, @pos, @pos + n)
      out = {}
      out[sub.str] = sub.str until sub.eof?
      @pos = sub.pos
      out
    end

    def map_u16_u64
      n = u32_peek_len
      sub = Cursor.new(@b, @pos, @pos + n)
      out = {}
      until sub.eof?
        k = sub.u16
        out[k] = sub.u64
      end
      @pos = sub.pos
      out
    end

    # Array<Tuple<Timestamp, uint64>>
    def tuples_u64
      n = u32_peek_len
      sub = Cursor.new(@b, @pos, @pos + n)
      out = []
      out << [ sub.u64, sub.u64 ] until sub.eof?
      @pos = sub.pos
      out
    end

    private

    # Takes a uint32 length and checks that so many bytes follow.
    def u32_peek_len
      n = u32
      raise FormatError, "length #{n} past the end of the record" if n > rest
      n
    end
  end

  # One record's body (not the opcode and length) as its Struct; nil for
  # an opcode this library does not know (private or newer records).
  def self.parse(op, body)
    c = Cursor.new(body)
    case op
    when HEADER then Header.new(c.str, c.str)
    when FOOTER then Footer.new(c.u64, c.u64, c.u32)
    when SCHEMA then Schema.new(c.u16, c.str, c.str, c.bytes32)
    when CHANNEL then Channel.new(c.u16, c.u16, c.str, c.str, c.map_ss)
    when MESSAGE then Message.new(c.u16, c.u32, c.u64, c.u64, body.byteslice(22, body.bytesize - 22) || "".b)
    when CHUNK then Chunk.new(c.u64, c.u64, c.u64, c.u32, c.str, c.bytes64)
    when MESSAGE_INDEX then MessageIndex.new(c.u16, c.tuples_u64)
    when CHUNK_INDEX then ChunkIndex.new(c.u64, c.u64, c.u64, c.u64, c.map_u16_u64, c.u64, c.str, c.u64, c.u64)
    when ATTACHMENT then Attachment.new(c.u64, c.u64, c.str, c.str, c.bytes64, c.u32)
    when ATTACHMENT_INDEX then AttachmentIndex.new(c.u64, c.u64, c.u64, c.u64, c.u64, c.str, c.str)
    when STATISTICS
      Statistics.new(c.u64, c.u16, c.u32, c.u32, c.u32, c.u32, c.u64, c.u64, c.map_u16_u64)
    when METADATA then Metadata.new(c.str, c.map_ss)
    when METADATA_INDEX then MetadataIndex.new(c.u64, c.u64, c.str)
    when SUMMARY_OFFSET then SummaryOffset.new(c.u8, c.u64, c.u64)
    when DATA_END then DataEnd.new(c.u32)
    end
  end
end
