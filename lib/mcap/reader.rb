require "zlib"

# Reads an MCAP file: from its summary when it has one (Footer -> summary
# section: schemas, channels, statistics, chunk indexes), else by scanning
# the data section from the start (a recording that stopped before its
# summary was written, or a writer that writes none). A file cut off in
# the middle of a record reads up to the last whole record (truncated?).
#
#   r = MCAP::Reader.new(path_or_io)
#   r.header                 # MCAP::Header (profile, library)
#   r.info                   # a Hash: channels with counts, schemas, start, end, ...
#   r.each_message { |msg, channel, schema| }   # in file order
#   r.index                  # { channel id => [[log_time, ref], ...] } sorted by time
#   r.message_at(ref)        # the MCAP::Message a ref points to
#
# Messages of compressed chunks raise UnsupportedCompression (see mcap.rb);
# the index of such a file still reads from its message index records.
module MCAP
  class Reader
    attr_reader :header, :footer, :size

    # source: a path or an IO open for binary reading (seekable).
    def initialize(source, verify_crc: true)
      @io = source.respond_to?(:read) ? source : File.open(source, "rb")
      @own = !source.respond_to?(:read)
      @io.binmode if @io.respond_to?(:binmode)
      @verify_crc = verify_crc
      @size = @io.size
      raise FormatError, "not an MCAP file (#{@size} bytes)" if @size < MAGIC.bytesize * 2 + 9
      raise FormatError, "not an MCAP file (bad magic)" unless read_at(0, 8) == MAGIC
      op, body, = record_at(8)
      raise FormatError, "the first record is not a Header" unless op == HEADER && body
      @header = MCAP.parse(op, body)
      @data_start = 8 + 9 + body.bytesize
      @footer = read_footer
      @truncated = false
    end

    def close
      @io.close if @own
    end

    def truncated? = @truncated

    # Whether the file has a summary section (else everything is scanned).
    def summary? = !summary.nil?

    # The summary: { schemas:, channels:, statistics:, chunk_indexes:,
    # attachment_indexes:, metadata_indexes: } read from the summary section,
    # or nil when the file has none.
    def summary
      return @summary if defined?(@summary)
      @summary = read_summary
    end

    def schemas = defs[:schemas]
    def channels = defs[:channels]

    # Schemas and channels: from the summary, or found by scanning.
    def defs
      @defs ||= if summary
        { schemas: summary[:schemas], channels: summary[:channels] }
      else
        scan[:defs]
      end
    end

    # What the file holds, for listing it:
    #   { "profile", "library", "messages", "start" / "end" (ns, or nil),
    #     "duration_ns", "chunks", "compression" => [..], "summary" => bool,
    #     "truncated" => bool, "metadata" => [names],
    #     "channels" => [{ "id", "topic", "message_encoding", "schema", "schema_encoding",
    #                      "metadata", "count" }] }
    def info
      @info ||= begin
        st = summary && summary[:statistics]
        counts, start, stop, chunks, comps, meta = if st && (st.channel_message_counts.any? || st.message_count.zero?)
          [ st.channel_message_counts, st.message_count.positive? ? st.message_start_time : nil,
            st.message_count.positive? ? st.message_end_time : nil, st.chunk_count,
            summary[:chunk_indexes].map(&:compression).uniq, summary[:metadata_indexes].map(&:name) ]
        else
          s = scan
          [ s[:counts], s[:start], s[:end], s[:chunks], s[:compression], s[:metadata] ]
        end
        {
          "profile" => @header.profile, "library" => @header.library,
          "messages" => counts.values.sum, "start" => start, "end" => stop,
          "duration_ns" => start && stop ? stop - start : 0, "chunks" => chunks, "compression" => comps,
          "summary" => summary?, "truncated" => truncated?, "metadata" => meta, "size" => @size,
          "channels" => channels.values.sort_by(&:id).map do |c|
            s = schemas[c.schema_id]
            { "id" => c.id, "topic" => c.topic, "message_encoding" => c.message_encoding,
              "schema" => s&.name, "schema_encoding" => s&.encoding, "metadata" => c.metadata,
              "count" => counts[c.id] || 0 }
          end
        }
      end
    end

    # Every message in file order, with its channel and schema (nil for
    # none). Raises UnsupportedCompression at the first compressed chunk.
    def each_message
      return enum_for(:each_message) unless block_given?
      each_data_record do |op, body, _at|
        case op
        when MESSAGE
          m = MCAP.parse(op, body)
          ch = channels[m.channel_id]
          yield m, ch, ch && schemas[ch.schema_id]
        when CHUNK
          chunk = MCAP.parse(op, body)
          records_of(chunk).each_record do |op2, body2, _|
            next unless op2 == MESSAGE
            m = MCAP.parse(op2, body2)
            ch = channels[m.channel_id]
            yield m, ch, ch && schemas[ch.schema_id]
          end
        end
      end
    end

    # The Metadata records: { name => { key => value } } (the last of a name).
    def metadata
      out = {}
      each_data_record { |op, body, _| (m = MCAP.parse(op, body)) && out[m.name] = m.metadata if op == METADATA }
      out
    end

    # Where every message is, by channel, sorted by log time:
    #   { channel id => [[log_time, ref], ...] }
    # ref: the file offset of the message record (an Integer), or for a
    # compressed chunk [chunk offset, offset in the chunk] (message_at raises
    # UnsupportedCompression for those). From the message index records when
    # the summary lists the chunks, else by scanning.
    def index
      @index ||= (summary && summary[:chunk_indexes].any? && index_from_summary) || index_by_scan
    end

    # The message at a ref of index.
    def message_at(ref)
      if ref.is_a?(Array)
        head = chunk_head_at(ref[0])
        raise UnsupportedCompression, head.compression unless head.compression.empty?
        ref = ref[0] + 9 + chunk_records_offset(head) + ref[1]
      end
      op, body, = record_at(ref)
      raise FormatError, "no message at #{ref}" unless op == MESSAGE && body
      MCAP.parse(op, body)
    end

    # Reads records of the data section in order: [opcode, body, file offset].
    # Stops at Data End (or the summary); a record cut off at the end of the
    # file ends it too (truncated? is then true).
    def each_data_record
      return enum_for(:each_data_record) unless block_given?
      pos = @data_start
      limit = data_limit
      while pos < limit
        op, body, len = record_at(pos, limit)
        unless body
          @truncated = true
          break
        end
        break if op == DATA_END || op == FOOTER
        yield op, body, pos
        pos += 9 + len
      end
    end

    # Checks every CRC the file has: the data section's (Data End), each
    # chunk's and the summary's. Returns true or raises FormatError.
    def verify!
      crc = Zlib.crc32(read_at(0, @data_start))
      pos = @data_start
      limit = data_limit
      while pos < limit
        op, body, len = record_at(pos, limit)
        raise FormatError, "cut off at #{pos}" unless body
        if op == DATA_END
          want = MCAP.parse(op, body).data_section_crc
          raise FormatError, "data section CRC mismatch" if want.positive? && want != crc
          break
        end
        records_of(MCAP.parse(op, body)) if op == CHUNK
        crc = Zlib.crc32(read_at(pos, 9 + len), crc)
        pos += 9 + len
      end
      summary
      true
    end

    private

    def read_at(pos, n)
      @io.seek(pos)
      @io.read(n) || "".b
    end

    # [opcode, body, length] of the record at pos; body nil when it runs
    # past limit (a cut-off file).
    def record_at(pos, limit = @size)
      head = read_at(pos, 9)
      return [ nil, nil, 0 ] if head.bytesize < 9
      op = head.getbyte(0)
      len = head.byteslice(1, 8).unpack1("Q<")
      return [ op, nil, len ] if pos + 9 + len > limit
      [ op, read_at(pos + 9, len), len ]
    end

    # Footer: the 20-byte record before the trailing magic (nil when the
    # file does not end with one: cut off, or still being written).
    def read_footer
      return nil unless read_at(@size - 8, 8) == MAGIC
      at = @size - 8 - 29
      return nil if at < @data_start
      op, body, len = record_at(at)
      return nil unless op == FOOTER && len == 20 && body
      @footer_at = at
      MCAP.parse(FOOTER, body)
    end

    # Where the data section ends (the summary or the footer, else the end).
    def data_limit
      return @size unless @footer
      @footer.summary_start.positive? ? @footer.summary_start : @footer_at
    end

    def read_summary
      return nil unless @footer && @footer.summary_start.positive?
      start = @footer.summary_start
      stop = @footer.summary_offset_start.positive? ? @footer.summary_offset_start : @footer_at
      raise FormatError, "summary past the footer" if start > stop || stop > @footer_at
      if @verify_crc && @footer.summary_crc.positive?
        bytes = read_at(start, @footer_at + 9 + 16 - start)
        crc = Zlib.crc32(bytes)
        raise FormatError, "summary CRC mismatch" unless crc == @footer.summary_crc
      end
      s = { schemas: {}, channels: {}, statistics: nil, chunk_indexes: [], attachment_indexes: [],
            metadata_indexes: [] }
      pos = start
      while pos < stop
        op, body, len = record_at(pos, stop)
        raise FormatError, "summary record past its end" unless body
        rec = MCAP.parse(op, body)
        case op
        when SCHEMA then s[:schemas][rec.id] = rec if rec.id.positive?
        when CHANNEL then s[:channels][rec.id] = rec
        when STATISTICS then s[:statistics] = rec
        when CHUNK_INDEX then s[:chunk_indexes] << rec
        when ATTACHMENT_INDEX then s[:attachment_indexes] << rec
        when METADATA_INDEX then s[:metadata_indexes] << rec
        end
        pos += 9 + len
      end
      # A summary without its channels (allowed when nothing indexes them):
      # take them from the data section.
      if s[:channels].empty? && s[:statistics]&.channel_count.to_i.positive?
        d = scan[:defs]
        s[:schemas] = d[:schemas]
        s[:channels] = d[:channels]
      end
      s
    end

    # A chunk's fields before its records (the records are not read): a
    # Chunk with records nil, or nil when there is no chunk at pos.
    def chunk_head_at(pos)
      head = read_at(pos, 9 + 32)
      return nil unless head.bytesize == 41 && head.getbyte(0) == CHUNK
      c = Cursor.new(head, 9)
      t0, t1, usize, crc = c.u64, c.u64, c.u64, c.u32
      n = c.u32
      Chunk.new(t0, t1, usize, crc, read_at(pos + 41, n), nil)
    end

    def chunk_records_offset(chunk)
      8 + 8 + 8 + 4 + 4 + chunk.compression.bytesize + 8
    end

    # The records of a chunk, uncompressed and checked.
    def records_of(chunk)
      raise UnsupportedCompression, chunk.compression unless chunk.compression.empty?
      if @verify_crc && chunk.uncompressed_crc.positive? && Zlib.crc32(chunk.records) != chunk.uncompressed_crc
        raise FormatError, "chunk CRC mismatch"
      end
      Records.new(chunk.records)
    end

    # Records inside a chunk's records field.
    class Records
      def initialize(bytes)
        @b = bytes
      end

      def each_record
        pos = 0
        n = @b.bytesize
        while pos + 9 <= n
          op = @b.getbyte(pos)
          len = @b.byteslice(pos + 1, 8).unpack1("Q<")
          raise FormatError, "chunk record past the chunk's end" if pos + 9 + len > n
          yield op, @b.byteslice(pos + 9, len), pos
          pos += 9 + len
        end
      end
    end

    # One pass over the data section: definitions, counts, times, and where
    # every message is.
    def scan
      @scan ||= begin
        out = { defs: { schemas: {}, channels: {} }, counts: Hash.new(0), start: nil, end: nil, chunks: 0,
                compression: [], metadata: [], index: Hash.new { |h, k| h[k] = [] } }
        note = lambda do |m, ref|
          out[:counts][m.channel_id] += 1
          out[:start] = m.log_time if out[:start].nil? || m.log_time < out[:start]
          out[:end] = m.log_time if out[:end].nil? || m.log_time > out[:end]
          out[:index][m.channel_id] << [ m.log_time, ref ]
        end
        define = lambda do |op, body|
          rec = MCAP.parse(op, body)
          if op == SCHEMA
            out[:defs][:schemas][rec.id] = rec if rec.id.positive?
          else
            out[:defs][:channels][rec.id] = rec
          end
        end
        compressed_at = nil # the compressed chunk the message indexes that follow belong to
        each_data_record do |op, body, at|
          case op
          when SCHEMA, CHANNEL then define.(op, body)
          when MESSAGE then note.(message_head(body), at)
          when METADATA then out[:metadata] << MCAP.parse(op, body).name
          when CHUNK
            out[:chunks] += 1
            chunk = MCAP.parse(op, body)
            out[:compression] |= [ chunk.compression ]
            compressed_at = chunk.compression.empty? ? nil : at
            if compressed_at.nil?
              base = at + 9 + chunk_records_offset(chunk)
              records_of(chunk).each_record do |op2, body2, off|
                case op2
                when SCHEMA, CHANNEL then define.(op2, body2)
                when MESSAGE then note.(message_head(body2), base + off)
                end
              end
            end
          when MESSAGE_INDEX
            # The messages of a compressed chunk are known by its index.
            if compressed_at
              mi = MCAP.parse(op, body)
              mi.records.each { |t, off| note.(Message.new(mi.channel_id, 0, t, t, nil), [ compressed_at, off ]) }
            end
          end
          compressed_at = nil unless [ CHUNK, MESSAGE_INDEX ].include?(op)
        end
        out[:counts] = out[:counts].to_h
        out
      end
    end

    # Channel id, sequence and times of a message body, without its data.
    def message_head(body)
      c = Cursor.new(body)
      Message.new(c.u16, c.u32, c.u64, c.u64, nil)
    end

    def index_by_scan
      scan[:index].transform_values { |list| list.sort_by(&:first) }.to_h
    end

    def index_from_summary
      out = Hash.new { |h, k| h[k] = [] }
      summary[:chunk_indexes].each do |ci|
        return nil if ci.message_index_offsets.empty? && ci.message_end_time.positive?
        chunk_head = chunk_head_at(ci.chunk_start_offset)
        return nil unless chunk_head
        base = ci.chunk_start_offset + 9 + chunk_records_offset(chunk_head)
        compressed = !ci.compression.empty?
        ci.message_index_offsets.each do |cid, at|
          op2, body2, = record_at(at)
          return nil unless op2 == MESSAGE_INDEX
          MCAP.parse(op2, body2).records.each do |t, off|
            out[cid] << [ t, compressed ? [ ci.chunk_start_offset, off ] : base + off ]
          end
        end
      end
      out.transform_values { |list| list.sort_by(&:first) }.to_h
    end
  end
end
