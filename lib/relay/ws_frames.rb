# The WebSocket side of a door that hands a browser's Zenoh session to
# zenohd's mutual-TLS port (G2's rooms, Relay::RoomDoor; T8's browsers,
# Relay::BrowserDoor): reading the browser's frames (masked, at most
# @max_message bytes), writing the door's, and the first batch from zenohd
# (InitAck) with its batch size lowered by 2 (on TLS the length takes 2
# bytes of the receiver's buffer too; fmruby-core
# doc/ruby_asterism/report/g1_5.md 7). One WebSocket Binary message is one
# batch; on TLS a batch is a 2-byte little-endian length and the batch.
require "openssl"

module Relay
  module WsFrames
    def read_exact(io, n)
      buf = io.read(n)
      raise EOFError, "short read" if buf.nil? || buf.bytesize < n
      buf
    end

    # One frame from the browser: [fin, opcode, payload]. Browsers mask
    # every frame (RFC 6455); a frame larger than the largest message is
    # not read.
    def ws_read_frame(io)
      b0, b1 = read_exact(io, 2).unpack("CC")
      raise IOError, "an unmasked frame" if (b1 & 0x80).zero?
      len = b1 & 0x7f
      # The 7-bit length decides alone: a 16-bit length of exactly 127 is a
      # 127-byte frame, not the mark of a 64-bit length.
      len = case len
      when 126 then read_exact(io, 2).unpack1("n")
      when 127 then read_exact(io, 8).unpack1("Q>")
      else len
      end
      raise IOError, "a #{len}-byte frame" if len > @max_message
      mask = read_exact(io, 4)
      data = read_exact(io, len)
      [ (b0 & 0x80) != 0, b0 & 0x0f, unmask(data, mask) ]
    end

    def unmask(data, mask)
      return data if data.empty?
      m = (mask * ((data.bytesize + 3) / 4)).byteslice(0, data.bytesize)
      # XOR 8 bytes at a time, then the rest.
      out = String.new(capacity: data.bytesize, encoding: Encoding::BINARY)
      full = data.bytesize / 8 * 8
      a = data.byteslice(0, full).unpack("Q*")
      b = m.byteslice(0, full).unpack("Q*")
      out << a.each_index.map { a[_1] ^ b[_1] }.pack("Q*")
      (full...data.bytesize).each { |i| out << (data.getbyte(i) ^ m.getbyte(i)).chr }
      out
    end

    def ws_write(io, opcode, data, wlock)
      n = data.bytesize
      head = if n < 126 then [ 0x80 | opcode, n ].pack("CC")
      elsif n < 65_536 then [ 0x80 | opcode, 126, n ].pack("CCn")
      else [ 0x80 | opcode, 127, n ].pack("CCQ>")
      end
      wlock.synchronize { io.write(head + data) }
    end

    # InitAck: header 0x21 (+0x40 S: sizes follow, +0x80 Z), version, flags
    # (the zid's size - 1 in the high nibble), zid, [S: resolution, batch
    # size u16 LE], cookie... Lowers the batch size by 2 (the TLS length's
    # 2 bytes). Returns [batch, old size or nil].
    def self.rewrite_init_ack(batch)
      h = batch.getbyte(0)
      return [ batch, nil ] unless h && (h & 0x1f) == 0x01 && (h & 0x20) != 0 && batch.bytesize >= 3
      at = 3 + (batch.getbyte(2) >> 4) + 1
      out = batch.dup
      if (h & 0x40) != 0
        old = batch.byteslice(at + 1, 2).unpack1("v")
        out[at + 1, 2] = [ old - 2 ].pack("v")
        [ out, old ]
      else # the default sizes (resolution 0x0a, batch 65535): written out
        out.setbyte(0, h | 0x40)
        out.insert(at, [ 0x0a, 65_535 - 2 ].pack("Cv"))
        [ out, 65_535 ]
      end
    end
  end
end
