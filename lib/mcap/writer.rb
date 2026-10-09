require "zlib"

# Writes an MCAP file, chunked and indexed, as rosbag2 and libmcap do:
#
#   Magic Header
#   Chunk (Schema, Channel and Message records, uncompressed)  Message Index...  (repeated)
#   Metadata...
#   Data End
#   Schema... Channel... Statistics Chunk Index... Metadata Index...   (the summary)
#   Summary Offset...
#   Footer Magic
#
# Schemas and channels go into the chunk that first needs them; a chunk is
# closed when its records reach chunk_size bytes (or by flush), so a
# recording that stops without finish loses at most the open chunk, and the
# rest still reads (MCAP::Reader scans a file that has no summary).
#
# All CRCs are written: each chunk's, the data section's (Data End) and the
# summary's (Footer). Times are nanoseconds (Integer).
module MCAP
  class Writer
    DEFAULT_CHUNK_SIZE = 768 * 1024

    attr_reader :message_count, :bytes_written, :message_start_time, :message_end_time, :channel_counts

    # io: an IO opened for binary writing (it is not closed here).
    def initialize(io, profile: "", library: "asterism-console mcap #{VERSION}", chunk_size: DEFAULT_CHUNK_SIZE)
      @io = io
      @chunk_size = chunk_size
      @bytes_written = 0
      @data_crc = 0
      @schemas = {}     # id => Schema
      @schema_ids = {}  # [name, encoding, data] => id
      @channels = {}    # id => Channel
      @channel_ids = {}
      @written_schema = {} # ids already in some chunk
      @written_channel = {}
      @chunk_indexes = []
      @metadata_indexes = []
      @metadata_count = 0
      @message_count = 0
      @channel_counts = Hash.new(0)
      @message_start_time = nil
      @message_end_time = nil
      @finished = false
      new_chunk
      emit(MAGIC)
      emit(Codec.record(HEADER, Codec.str(profile) + Codec.str(library)))
    end

    def finished? = @finished

    # The id of a schema (the same schema given again gets the same id).
    # encoding "" with empty data means no schema; channels then use 0.
    def add_schema(name:, encoding:, data:)
      key = [ name.to_s, encoding.to_s, data.to_s.b ]
      @schema_ids[key] ||= begin
        id = @schemas.size + 1
        raise Error, "too many schemas" if id > 0xffff
        @schemas[id] = Schema.new(id, *key)
        id
      end
    end

    def add_channel(topic:, message_encoding:, schema_id: 0, metadata: {})
      raise Error, "unknown schema #{schema_id}" unless schema_id.zero? || @schemas.key?(schema_id)
      meta = metadata.to_h { |k, v| [ k.to_s, v.to_s ] }
      key = [ topic.to_s, message_encoding.to_s, schema_id, meta.to_a ]
      @channel_ids[key] ||= begin
        id = @channels.size + 1
        raise Error, "too many channels" if id > 0xffff
        @channels[id] = Channel.new(id, schema_id, topic.to_s, message_encoding.to_s, meta)
        id
      end
    end

    def channel(id) = @channels[id]
    def channels = @channels.values

    # One message. log_time: when it was received (ns), publish_time: when it
    # was sent (ns; the log time when not known), sequence: uint32 (0 when
    # not known).
    def add_message(channel_id:, log_time:, data:, publish_time: nil, sequence: 0)
      raise Error, "finished" if @finished
      ch = @channels[channel_id] or raise Error, "unknown channel #{channel_id}"
      put_definitions(ch)
      log_time = log_time.to_i
      body = Codec.u16(channel_id) + Codec.u32(sequence.to_i & 0xffffffff) + Codec.u64(log_time) +
             Codec.u64((publish_time || log_time).to_i) + data.to_s.b
      (@chunk_index_of[channel_id] ||= []) << [ log_time, @chunk.bytesize ]
      @chunk << Codec.record(MESSAGE, body)
      @chunk_start = log_time if @chunk_start.nil? || log_time < @chunk_start
      @chunk_end = log_time if @chunk_end.nil? || log_time > @chunk_end
      @chunk_messages += 1
      @message_count += 1
      @channel_counts[channel_id] += 1
      @message_start_time = log_time if @message_start_time.nil? || log_time < @message_start_time
      @message_end_time = log_time if @message_end_time.nil? || log_time > @message_end_time
      flush if @chunk.bytesize >= @chunk_size
      nil
    end

    # A Metadata record (name and string pairs), outside the chunks.
    def add_metadata(name, metadata)
      raise Error, "finished" if @finished
      flush
      at = @bytes_written
      rec = Codec.record(METADATA, Codec.str(name) + Codec.map_ss(metadata))
      emit(rec)
      @metadata_indexes << MetadataIndex.new(at, rec.bytesize, name.to_s)
      @metadata_count += 1
    end

    # The bytes the file will have once the open chunk is written (for size
    # limits).
    def size = @bytes_written + @chunk.bytesize

    # Writes the open chunk (if it has anything) and its message indexes.
    def flush
      return if @chunk.empty?
      records = @chunk
      start = @bytes_written
      body = Codec.u64(@chunk_start || 0) + Codec.u64(@chunk_end || 0) + Codec.u64(records.bytesize) +
             Codec.u32(Zlib.crc32(records)) + Codec.str("") + Codec.bytes64(records)
      emit(Codec.record(CHUNK, body))
      chunk_length = @bytes_written - start
      offsets = {}
      idx_start = @bytes_written
      @chunk_index_of.each do |cid, list|
        offsets[cid] = @bytes_written
        tuples = list.map { |t, o| Codec.u64(t) + Codec.u64(o) }.join.b
        emit(Codec.record(MESSAGE_INDEX, Codec.u16(cid) + Codec.u32(tuples.bytesize) + tuples))
      end
      @chunk_indexes << ChunkIndex.new(@chunk_messages.positive? ? @chunk_start : 0,
                                       @chunk_messages.positive? ? @chunk_end : 0, start, chunk_length, offsets,
                                       @bytes_written - idx_start, "", records.bytesize, records.bytesize)
      @io.flush if @io.respond_to?(:flush)
      new_chunk
    end

    # Ends the file: the open chunk, Data End, the summary, the summary
    # offsets and the footer. Returns the Statistics.
    def finish
      return @statistics if @finished
      flush
      emit(Codec.record(DATA_END, Codec.u32(@data_crc)))
      summary_start = @bytes_written
      @summary_crc = 0
      groups = []
      group = lambda do |op, recs|
        next if recs.empty?
        at = @bytes_written
        recs.each { summary_emit(_1) }
        groups << [ op, at, @bytes_written - at ]
      end
      group.(SCHEMA, @schemas.values.map { schema_record(_1) })
      group.(CHANNEL, @channels.values.map { channel_record(_1) })
      @statistics = Statistics.new(@message_count, @schemas.size, @channels.size, 0, @metadata_count,
                                   @chunk_indexes.size, @message_start_time || 0, @message_end_time || 0,
                                   @channel_counts.dup)
      group.(STATISTICS, [ statistics_record(@statistics) ])
      group.(CHUNK_INDEX, @chunk_indexes.map { chunk_index_record(_1) })
      group.(METADATA_INDEX, @metadata_indexes.map do |m|
        Codec.record(METADATA_INDEX, Codec.u64(m.offset) + Codec.u64(m.length) + Codec.str(m.name))
      end)
      offset_start = @bytes_written
      groups.each do |op, at, len|
        summary_emit(Codec.record(SUMMARY_OFFSET, Codec.u8(op) + Codec.u64(at) + Codec.u64(len)))
      end
      head = Codec.u8(FOOTER) + Codec.u64(20) + Codec.u64(summary_start) + Codec.u64(offset_start)
      @summary_crc = Zlib.crc32(head, @summary_crc)
      emit(head + Codec.u32(@summary_crc))
      emit(MAGIC)
      @io.flush if @io.respond_to?(:flush)
      @finished = true
      @statistics
    end

    private

    def new_chunk
      @chunk = "".b
      @chunk_index_of = {}
      @chunk_start = nil
      @chunk_end = nil
      @chunk_messages = 0
    end

    def emit(bytes)
      @io.write(bytes)
      @bytes_written += bytes.bytesize
      @data_crc = Zlib.crc32(bytes, @data_crc)
    end

    def summary_emit(bytes)
      @io.write(bytes)
      @bytes_written += bytes.bytesize
      @summary_crc = Zlib.crc32(bytes, @summary_crc)
    end

    # The schema and channel records a message needs, into the open chunk
    # the first time.
    def put_definitions(ch)
      if ch.schema_id.positive? && !@written_schema[ch.schema_id]
        @chunk << schema_record(@schemas[ch.schema_id])
        @written_schema[ch.schema_id] = true
      end
      return if @written_channel[ch.id]
      @chunk << channel_record(ch)
      @written_channel[ch.id] = true
    end

    def schema_record(s)
      Codec.record(SCHEMA, Codec.u16(s.id) + Codec.str(s.name) + Codec.str(s.encoding) + Codec.bytes32(s.data))
    end

    def channel_record(c)
      Codec.record(CHANNEL, Codec.u16(c.id) + Codec.u16(c.schema_id) + Codec.str(c.topic) +
                            Codec.str(c.message_encoding) + Codec.map_ss(c.metadata))
    end

    def statistics_record(s)
      Codec.record(STATISTICS, Codec.u64(s.message_count) + Codec.u16(s.schema_count) + Codec.u32(s.channel_count) +
                               Codec.u32(s.attachment_count) + Codec.u32(s.metadata_count) +
                               Codec.u32(s.chunk_count) + Codec.u64(s.message_start_time) +
                               Codec.u64(s.message_end_time) + Codec.map_u16_u64(s.channel_message_counts.sort.to_h))
    end

    def chunk_index_record(ci)
      Codec.record(CHUNK_INDEX, Codec.u64(ci.message_start_time) + Codec.u64(ci.message_end_time) +
                                Codec.u64(ci.chunk_start_offset) + Codec.u64(ci.chunk_length) +
                                Codec.map_u16_u64(ci.message_index_offsets) + Codec.u64(ci.message_index_length) +
                                Codec.str(ci.compression) + Codec.u64(ci.compressed_size) +
                                Codec.u64(ci.uncompressed_size))
    end
  end
end
