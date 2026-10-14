# The rooms' door (G2, docs/rooms.md), run by bin/ws_door next to the
# browsers' pass door. A browser in a room opens a WebSocket to
# wss://<router>/room?t=<the room's key>; the web server (nginx) ends TLS
# and hands it here. The door:
#
# 1. reads the request head (within HEAD_SECONDS, at most HEAD_MAX bytes)
#    and checks the key: its signature with the signer's public keys, its
#    end, that its room still holds its slot and is not revoked (the
#    rooms' file the console writes, Relay::RoomFiles), and the limits (per
#    room, for every room together). Until all of that passes, nothing goes
#    to zenohd: not a connection, not a byte.
# 2. cuts whatever is left on the key's slot of an earlier room (a slot is
#    used again for a later room only after its connections are gone);
# 3. connects to zenohd's mutual-TLS port with the slot's certificate
#    (room-<slot>), whose ACL is the slot's key space only
#    (Relay::CloudConfig), answers 101 itself, and moves the Zenoh batches
#    between the two framings: one WebSocket Binary message is one batch,
#    on TLS a batch is a 2-byte little-endian length and the batch. The first
#    batch from zenohd (InitAck) has its batch size lowered by 2, since on
#    TLS the length takes 2 bytes of the receiver's buffer too;
# 4. closes the connection when the key ends (24 hours at most), when its
#    room is closed early, or when the room's slot is given to another room.
#
# Keys whose signature does not check are counted per address; past
# BAD_LIMIT in BAD_WINDOW seconds such an address is answered 429 for
# BAD_BLOCK seconds, and its refusals are no longer logged one by one. A
# key that checks is let in whatever its address did before (many people
# at one event come from one address). nginx limits the rate of attempts
# in front of this (limit_req).
#
# Answers: 400 not a WebSocket request to /room, 403 a key that does not
# check, 410 a room that has ended or is closed, 429 see above, 503 the
# room or the door is full or zenohd is not there. The key is never logged.
#
# Plain Ruby (the standard library and lib/relay/room_token.rb): two
# threads per connection, so run it with a small thread stack
# (RUBY_THREAD_VM_STACK_SIZE=131072, MALLOC_ARENA_MAX=2; deploy/vps).
require "socket"
require "openssl"
require "json"
require "digest"
require "base64"
require "uri"
require "time"
require_relative "room_token"

module Relay
  class RoomDoor
    WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze
    HEAD_MAX = 8 * 1024
    HEAD_SECONDS = 5.0
    PENDING_MAX = 64
    BAD_LIMIT = 30
    BAD_WINDOW = 60.0
    BAD_BLOCK = 60.0
    CHECK_SECONDS = 0.5
    # A key may say it ends up to this far past the signer's cap (clocks).
    SKEW = 300
    STATUS = { 400 => "Bad Request", 403 => "Forbidden", 410 => "Gone", 429 => "Too Many Requests",
               503 => "Service Unavailable" }.freeze

    # One connection: the browser's socket, zenohd's, and what it is for.
    Conn = Struct.new(:client, :tls, :room, :slot, :ends_at, :ip, :opened_at, :closing, keyword_init: true) do
      def close(reason, log)
        return if closing
        self.closing = true
        log.call("room #{room} slot #{slot}: closing a connection from #{ip} (#{reason})")
        [ tls, client ].each do |s|
          s&.close
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        end
      end
    end

    attr_reader :listen_port, :status_port

    # listen / status_listen: "host:port" (port 0: any free one, for tests).
    # upstream: zenohd's mutual-TLS listener; tls_name: the name its
    # certificate carries. rooms_file: Relay::RoomFiles' file. certs_dir:
    # room-<slot>.pem / .key and ca.pem.
    def initialize(listen:, upstream:, rooms_file:, certs_dir:, status_listen: nil, tls_name: nil,
                   total: 48, per_room: RoomToken::MAX_CONNECTIONS, max_message: 65_535,
                   max_hours: RoomToken::MAX_HOURS, head_seconds: HEAD_SECONDS, log: ->(m) { $stdout.puts(m) })
      @listen = listen
      @upstream = upstream
      @tls_name = tls_name || split_hostport(upstream)[0]
      @rooms_file = rooms_file
      @certs_dir = certs_dir
      @status_listen = status_listen
      @total = total
      @per_room = per_room
      @max_message = max_message
      @max_hours = max_hours
      @head_seconds = head_seconds
      @log = log
      @lock = Mutex.new
      @conns = []
      @pending = 0
      @bad = Hash.new { |h, k| h[k] = [] }
      @blocked = {}
      @rooms = { "keys" => {}, "slots" => {}, "revoked" => {} }
      @rooms_mtime = :none
      @contexts = {}
      @threads = []
      @counts = Hash.new(0)
      @started_at = Time.now.utc
    end

    def start
      @server = TCPServer.new(*split_hostport(@listen))
      @listen_port = @server.addr[1]
      reload_rooms
      @threads << Thread.new { accept_loop }
      @threads << Thread.new { watch_loop }
      if @status_listen
        @status_server = TCPServer.new(*split_hostport(@status_listen))
        @status_port = @status_server.addr[1]
        @threads << Thread.new { status_loop }
      end
      log("rooms: listening on #{@listen}, to #{@upstream} (TLS name #{@tls_name}), at most #{@total} " \
          "connections, #{@per_room} per room, messages up to #{@max_message} bytes")
      self
    end

    def stop
      [ @server, @status_server ].each { _1&.close rescue nil }
      @threads.each(&:kill)
      @lock.synchronize { @conns.dup }.each { _1.close("the door stops", @log) }
    end

    # {"rooms" => {uid => n}, "slots" => {slot => n}, "total", "limit", "per_room", ...}
    def status
      @lock.synchronize do
        live = @conns.reject(&:closing)
        { "rooms" => live.group_by(&:room).transform_values(&:size),
          "slots" => live.group_by(&:slot).transform_values(&:size),
          "total" => live.size, "limit" => @total, "per_room" => @per_room, "pending" => @pending,
          "refused" => @counts.dup, "since" => @started_at.iso8601 }
      end
    end

    private

    def log(msg) = @log.call(msg)

    def split_hostport(s)
      host, _, port = s.rpartition(":")
      [ host.delete_prefix("[").delete_suffix("]"), Integer(port) ]
    end

    def accept_loop
      loop do
        client = @server.accept
        busy = @lock.synchronize { @pending >= PENDING_MAX || (@pending += 1).nil? }
        if busy
          # Answered, not just closed: nginx logs the request line (the key
          # with it) for an upstream that closes without an answer.
          Thread.new(client) do |c|
            answer(c, 503)
          ensure
            c.close rescue nil
          end
          next
        end
        Thread.new(client) { |c| serve(c) }
      end
    rescue IOError, SystemCallError
      nil
    end

    # ------------------------------------------------------------ the check

    def reload_rooms
      mtime = File.mtime(@rooms_file) rescue nil
      return if mtime == @rooms_mtime
      data = mtime ? JSON.parse(File.read(@rooms_file)) : {}
      keys = Array(data["keys"]).to_h { [ _1["kid"], OpenSSL::PKey.read(_1["public_key"]) ] }
      revoked = Array(data["revoked"]).to_h { [ _1["room"], _1["until"].to_i ] }
      @lock.synchronize do
        @rooms = { "keys" => keys, "slots" => data["slots"].is_a?(Hash) ? data["slots"] : {}, "revoked" => revoked }
        @rooms_mtime = mtime
      end
      log("rooms: #{mtime ? 'read' : 'no'} #{@rooms_file}: #{keys.size} key(s), #{@rooms['slots'].size} open room(s), " \
          "#{revoked.size} revoked")
    rescue JSON::ParserError, OpenSSL::PKey::PKeyError, SystemCallError, NoMethodError, TypeError => e
      # A file being written is replaced whole (rename), so this is a broken
      # file: let no room in until it is good again.
      @lock.synchronize do
        @rooms = { "keys" => {}, "slots" => {}, "revoked" => {} }
        @rooms_mtime = mtime
      end
      log("rooms: #{@rooms_file} is unreadable (#{e.class}): no room is let in until it is fixed")
    end

    # Whether the room of conn (or of claims) may still be open: its slot
    # holds it and it is not revoked.
    def room_open?(room, slot, now)
      held = @rooms["slots"][slot]
      return false unless held.is_a?(Hash) && held["room"] == room && held["until"].to_i > now
      !@rooms["revoked"].key?(room)
    end

    def bad_key(ip, now)
      list = @bad[ip]
      list.reject! { now - _1 > BAD_WINDOW }
      list << now
      return unless list.size > BAD_LIMIT && !@blocked.key?(ip)
      @blocked[ip] = now + BAD_BLOCK
      log("rooms: #{ip} sent #{list.size} keys that do not check within #{BAD_WINDOW.round} s: " \
          "answering 429 to its keys that do not check for #{BAD_BLOCK.round} s")
    end

    # [claims, conn] or [nil, status, why, quiet]. Takes a place for the
    # connection (under the lock) when it passes: release it with #forget.
    def admit(token, ip)
      reload_rooms
      now = Time.now.to_f
      claims = nil
      reason = nil
      @lock.synchronize do
        @blocked.delete(ip) if @blocked[ip] && @blocked[ip] <= now
        begin
          claims = RoomToken.verify(token, @rooms["keys"], now: now.to_i)
        rescue RoomToken::Invalid => e
          reason = e.message
        end
        if reason == "expired"
          return [ nil, 410, "the key has ended" ]
        elsif reason
          blocked = @blocked.key?(ip)
          bad_key(ip, now)
          return [ nil, blocked ? 429 : 403, "a key that does not check (#{reason})", blocked ]
        end
        return [ nil, 403, "a key that ends past the cap" ] if claims["exp"] > now + @max_hours * 3600 + SKEW
        return [ nil, 410, "room #{claims['room']} is closed or no longer on slot #{claims['slot']}" ] unless
          room_open?(claims["room"], claims["slot"], now)
        live = @conns.reject(&:closing)
        held = @rooms["slots"][claims["slot"]]
        limit = [ claims["max"], held["max"].to_i.positive? ? held["max"].to_i : claims["max"], @per_room ].min
        return [ nil, 503, "room #{claims['room']} is full (#{limit})" ] if live.count { _1.room == claims["room"] } >= limit
        return [ nil, 503, "the door is full (#{@total})" ] if live.size >= @total
        stale = live.select { _1.slot == claims["slot"] && _1.room != claims["room"] }
        stale.each { _1.close("slot #{claims['slot']} is now room #{claims['room']}'s", @log) }
        conn = Conn.new(room: claims["room"], slot: claims["slot"], ip: ip, opened_at: now,
                        ends_at: [ claims["exp"].to_f, now + @max_hours * 3600 ].min)
        @conns << conn
        [ claims, conn ]
      end
    end

    def forget(conn)
      @lock.synchronize { @conns.delete(conn) }
    end

    def watch_loop
      loop do
        sleep CHECK_SECONDS
        reload_rooms
        now = Time.now.to_f
        cut = @lock.synchronize do
          @conns.reject(&:closing).filter_map do |c|
            next [ c, "its key has ended" ] if now >= c.ends_at
            next [ c, "its room is closed or no longer on its slot" ] unless room_open?(c.room, c.slot, now)
            nil
          end
        end
        cut.each { |c, why| c.close(why, @log) }
      end
    rescue StandardError => e
      log("rooms: the watch stopped (#{e.class}: #{e.message}); restarting it")
      retry
    end

    # --------------------------------------------------------- the request

    # The head, read without reading past it, within HEAD_SECONDS.
    def read_head(io)
      head = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @head_seconds
      until head.end_with?("\r\n\r\n")
        return nil if head.bytesize > HEAD_MAX
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if left <= 0 || !io.wait_readable(left)
        head << io.readpartial(1)
      end
      head
    rescue EOFError, IOError, SystemCallError
      nil
    end

    def answer(io, code)
      io.write("HTTP/1.1 #{code} #{STATUS[code]}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue IOError, SystemCallError
      nil
    end

    def serve(client)
      conn = nil
      pending = true
      head = read_head(client)
      peer = (client.peeraddr[3] rescue "?")
      ip = head && head[/^X-Forwarded-For:\s*([^,\r\n]+)/i, 1]&.strip || peer
      line = head.to_s.lines.first.to_s
      verb, target, = line.split(" ", 3)
      path, query = target.to_s.split("?", 2)
      key = head.to_s[/^Sec-WebSocket-Key:\s*(\S+)/i, 1]
      unless head && verb == "GET" && path == "/room" && key && head.match?(/^Upgrade:\s*websocket\s*$/i)
        @lock.synchronize { @counts["400"] += 1 }
        answer(client, 400) if head
        return log("rooms: refused #{ip}: 400 (#{head ? 'not a WebSocket request to /room' : 'no request head in time'})")
      end
      token = URI.decode_www_form(query.to_s).to_h["t"].to_s rescue ""
      claims, got, why, quiet = admit(token, ip)
      unless claims
        @lock.synchronize { @counts[got.to_s] += 1 }
        answer(client, got)
        return quiet ? nil : log("rooms: refused #{ip}: #{got} (#{why})")
      end
      conn = got
      conn.client = client
      @lock.synchronize { @pending -= 1 }
      pending = false
      tls = connect_upstream(claims["slot"])
      unless tls
        answer(client, 503)
        return log("rooms: room #{claims['room']} slot #{claims['slot']}: zenohd is not there; answered 503 to #{ip}")
      end
      conn.tls = tls
      if conn.closing # cut while connecting
        tls.close rescue nil
        return
      end
      accept = Base64.strict_encode64(Digest::SHA1.digest(key + WS_GUID))
      client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
      [ client, tls.to_io ].each { _1.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil }
      n = @lock.synchronize { @conns.count { _1.room == claims["room"] && !_1.closing } }
      log("rooms: room #{claims['room']} slot #{claims['slot']}: open from #{ip} (#{n} in the room), until " \
          "#{Time.at(conn.ends_at).utc.strftime('%Y-%m-%dT%H:%M:%SZ')}")
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pump(conn)
      log("rooms: room #{claims['room']} slot #{claims['slot']}: closed from #{ip} after " \
          "#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)} s")
    rescue StandardError => e
      log("rooms: #{e.class}: #{e.message}")
      answer(client, 503) if conn.nil? || conn.tls.nil?
    ensure
      @lock.synchronize { @pending -= 1 } if pending
      if conn
        conn.closing = true
        forget(conn)
      end
      [ conn&.tls, client ].each { _1&.close rescue nil }
    end

    def context(slot)
      cert_file = File.join(@certs_dir, "room-#{slot}.pem")
      mtime = File.mtime(cert_file)
      cached = @contexts[slot]
      return cached[1] if cached && cached[0] == mtime
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(cert_file))
      ctx.key = OpenSSL::PKey.read(File.read(File.join(@certs_dir, "room-#{slot}.key")))
      ctx.ca_file = File.join(@certs_dir, "ca.pem")
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.verify_hostname = true
      @contexts[slot] = [ mtime, ctx ]
      ctx
    end

    def connect_upstream(slot)
      tcp = Socket.tcp(*split_hostport(@upstream), connect_timeout: 3)
      tls = OpenSSL::SSL::SSLSocket.new(tcp, context(slot))
      tls.hostname = @tls_name
      tls.sync_close = true
      tls.connect
      tls
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError, SocketError => e
      log("rooms: slot #{slot}: no TLS link to #{@upstream} (#{e.class}: #{e.message})")
      tcp&.close rescue nil
      nil
    end

    # ---------------------------------------------------------- the streams

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
      len = read_exact(io, 2).unpack1("n") if len == 126
      len = read_exact(io, 8).unpack1("Q>") if len == 127
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

    def pump(conn)
      client = conn.client
      tls = conn.tls
      wlock = Mutex.new
      up = Thread.new do # browser -> zenohd
        msg = +""
        loop do
          fin, op, data = ws_read_frame(client)
          case op
          when 0x2, 0x0
            msg << data
            raise IOError, "a #{msg.bytesize}-byte message" if msg.bytesize > [ @max_message, 65_535 ].min
            next unless fin
            tls.write([ msg.bytesize ].pack("v") + msg)
            msg = +""
          when 0x9 then ws_write(client, 0xA, data, wlock)
          when 0xA then nil
          when 0x8 then break
          else raise IOError, "WebSocket opcode #{op}"
          end
        end
      rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        log("rooms: room #{conn.room}: from the browser: #{e.message}") unless conn.closing || e.is_a?(EOFError)
      ensure
        conn.close("the browser side ended", ->(_) { }) unless conn.closing
      end
      first = true
      begin
        loop do # zenohd -> browser
          len = read_exact(tls, 2).unpack1("v")
          batch = read_exact(tls, len)
          if first
            batch, = self.class.rewrite_init_ack(batch)
            first = false
          end
          ws_write(client, 0x2, batch, wlock)
        end
      rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        conn.close("zenohd's side ended", ->(_) { }) unless conn.closing
      end
      up.join
    end

    # -------------------------------------------------------------- status

    def status_loop
      loop do
        c = @status_server.accept
        Thread.new(c) do |s|
          line = s.gets("\r\n", 1024).to_s
          nil while (h = s.gets("\r\n", 1024)) && h != "\r\n"
          body = line.start_with?("GET /status ") ? JSON.generate(status) : nil
          s.write(body ? "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                         "Connection: close\r\n\r\n#{body}" : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        rescue StandardError => e
          log("rooms: status: #{e.class}: #{e.message}") unless e.is_a?(IOError) || e.is_a?(SystemCallError)
        ensure
          s.close rescue nil
        end
      end
    rescue IOError, SystemCallError
      nil
    end
  end
end
