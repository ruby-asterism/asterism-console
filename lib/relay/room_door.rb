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
# 3. answers 101 itself and waits for the page's first message, a Text
#    with {"s": <the page's secret for the room>}: the page has taken a
#    seat with it before (below). Only when the secret has a seat does it
#    connect to zenohd's mutual-TLS port, with the seat's certificate
#    (room-<slot>-s<seat>), whose ACL is the slot's key space with the
#    page's writes and calls bound to the seat's node ID
#    (Relay::CloudConfig). Then it moves the Zenoh batches between the two
#    framings: one WebSocket Binary message is one batch, on TLS a batch is
#    a 2-byte little-endian length and the batch. The first batch from
#    zenohd (InitAck) has its batch size lowered by 2, since on TLS the
#    length takes 2 bytes of the receiver's buffer too;
# 4. closes the connection when the key ends (24 hours at most), when its
#    room is closed early, or when the room's slot is given to another room.
#
# Seats (0.3.0, docs/rooms.md "Seats"): the page first takes a seat: POST
# /room/seat with {"t": <the room's key>, "s": <its secret for the room>}
# in the body (never in the URL or a header); the door checks the key as
# above, looks the SHA-256 of "<room>:<secret>" up in its seats' table (a
# file of its own, seats_file: it never holds a secret) and answers
# {"node": "wasm-0103", "seat": "03"}: the same seat for the same secret
# until the room is over, a free seat for a new one, a seat nobody has
# been connected on for seat_idle seconds (30 minutes) when no seat is
# free, else 409. A slot has the seats the router's configuration lets in
# (rooms.json "seats"); one with none (not applied yet) lets nobody in:
# 404 to the seat request, 503 to the WebSocket. The WebSocket is closed
# with 4403 (no seat for this secret), 4408 (no secret in time), 4426 (a
# Binary first: a page from before 0.3.0, which sends no secret), 1013
# (zenohd is not there). A room that is over loses its seats.
#
# Coming back (0.3.9, docs/rooms.md): a page keeps its secret in the
# browser, so a tab opened again (or a second tab) asks for its seat with
# the same secret and gets the same seat, the same node. That seat request
# cuts the connections still on the seat (the older page's: 4403, see
# #cut_older_page); a page's own sessions and reconnections come without
# one and cut nothing.
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
# room or the door is full or the room's slot has no seats. POST /room/seat: 200,
# 400 (no key and secret in the body), 403, 404 (the room's slot has no
# seats), 409 (every seat is taken), 410, 429. Neither the key nor a secret
# (nor its hash) is ever logged.
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
    STATUS = { 200 => "OK", 204 => "No Content", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
               405 => "Method Not Allowed", 409 => "Conflict", 410 => "Gone", 411 => "Length Required",
               429 => "Too Many Requests", 503 => "Service Unavailable" }.freeze
    # Seats (0.3.0).
    BODY_MAX = 2048
    SECRET = /\A[0-9a-f]{32}\z/
    SEAT_IDLE = 1800.0
    SEAT_WAIT = 5.0
    TOUCH_EVERY = 60.0
    # After a refusal's close frame: how long to read what the page still
    # sends (in all, and with nothing coming) before the socket is closed.
    LINGER = 2.0
    LINGER_IDLE = 0.3
    # WebSocket close codes the page can tell apart.
    CLOSE_NO_SEAT = 4403
    CLOSE_NO_SECRET = 4408
    CLOSE_OLD_PAGE = 4426
    CLOSE_TRY_AGAIN = 1013

    # One connection: the browser's socket, zenohd's, and what it is for.
    Conn = Struct.new(:client, :tls, :room, :slot, :seat, :ends_at, :ip, :opened_at, :closing, :upgraded,
                      :wlock, :taken, keyword_init: true) do
      def label = "room #{room} slot #{slot}#{" seat #{seat}" if seat}"

      def close(reason, log)
        return if closing
        self.closing = true
        log.call("#{label}: closing a connection from #{ip} (#{reason})")
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
    # room-<slot>-s<seat>.pem / .key and ca.pem. seats_file: the seats'
    # table (nil: kept in memory only). seat_idle: seconds without a
    # connection after which a seat may go to another secret.
    def initialize(listen:, upstream:, rooms_file:, certs_dir:, status_listen: nil, tls_name: nil,
                   total: 48, per_room: RoomToken::MAX_CONNECTIONS, max_message: 65_535,
                   max_hours: RoomToken::MAX_HOURS, head_seconds: HEAD_SECONDS, seats_file: nil,
                   seat_idle: SEAT_IDLE, seat_wait: SEAT_WAIT, log: ->(m) { $stdout.puts(m) })
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
      @seats_file = seats_file
      @seat_idle = seat_idle
      @seat_wait = seat_wait
      @seats = {}
      @seats_ok = true
      @touched_at = 0.0
      @log = log
      @lock = Mutex.new
      @conns = []
      @pending = 0
      @bad = Hash.new { |h, k| h[k] = [] }
      @blocked = {}
      @rooms = { "keys" => {}, "slots" => {}, "revoked" => {}, "ok" => false, "prefix" => "wasm-" }
      @rooms_mtime = :none
      @contexts = {}
      @threads = []
      @counts = Hash.new(0)
      @started_at = Time.now.utc
    end

    def start
      @server = TCPServer.new(*split_hostport(@listen))
      @listen_port = @server.addr[1]
      load_seats
      reload_rooms
      @threads << Thread.new { accept_loop }
      @threads << Thread.new { watch_loop }
      if @status_listen
        @status_server = TCPServer.new(*split_hostport(@status_listen))
        @status_port = @status_server.addr[1]
        @threads << Thread.new { status_loop }
      end
      log("rooms: listening on #{@listen}, to #{@upstream} (TLS name #{@tls_name}), at most #{@total} " \
          "connections, #{@per_room} per room, messages up to #{@max_message} bytes; seats in " \
          "#{@seats_file || 'memory'}, given again after #{@seat_idle.round} s without a connection")
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
          "seats" => @seats.transform_values { _1["seats"].size },
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
      prefix = data["seat_node_prefix"].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,20}\z/) ? data["seat_node_prefix"] : "wasm-"
      @lock.synchronize do
        @rooms = { "keys" => keys, "slots" => data["slots"].is_a?(Hash) ? data["slots"] : {}, "revoked" => revoked,
                   "ok" => !mtime.nil?, "prefix" => prefix }
        @rooms_mtime = mtime
      end
      log("rooms: #{mtime ? 'read' : 'no'} #{@rooms_file}: #{keys.size} key(s), #{@rooms['slots'].size} open room(s), " \
          "#{revoked.size} revoked")
    rescue JSON::ParserError, OpenSSL::PKey::PKeyError, SystemCallError, NoMethodError, TypeError => e
      # A file being written is replaced whole (rename), so this is a broken
      # file: let no room in until it is good again.
      @lock.synchronize do
        @rooms = { "keys" => {}, "slots" => {}, "revoked" => {}, "ok" => false, "prefix" => "wasm-" }
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

    # The key's claims, or [nil, status, why, quiet]. Under the lock.
    def check_key(token, ip, now)
      @blocked.delete(ip) if @blocked[ip] && @blocked[ip] <= now
      reason = nil
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
      [ claims ]
    end

    # The seats of a slot the router lets in (rooms.json), 0: none.
    def seat_count(slot)
      held = @rooms["slots"][slot]
      held.is_a?(Hash) ? held["seats"].to_i.clamp(0, 99) : 0
    end

    # [claims, conn] or [nil, status, why, quiet]. Takes a place for the
    # connection (under the lock) when it passes: release it with #forget.
    def admit(token, ip)
      reload_rooms
      now = Time.now.to_f
      @lock.synchronize do
        claims, code, why, quiet = check_key(token, ip, now)
        return [ nil, code, why, quiet ] unless claims
        live = @conns.reject(&:closing)
        held = @rooms["slots"][claims["slot"]]
        limit = [ claims["max"], held["max"].to_i.positive? ? held["max"].to_i : claims["max"], @per_room ].min
        return [ nil, 503, "room #{claims['room']} is full (#{limit})" ] if live.count { _1.room == claims["room"] } >= limit
        return [ nil, 503, "the door is full (#{@total})" ] if live.size >= @total
        stale = live.select { _1.slot == claims["slot"] && _1.room != claims["room"] }
        stale.each { _1.close("slot #{claims['slot']} is now room #{claims['room']}'s", @log) }
        conn = Conn.new(room: claims["room"], slot: claims["slot"], ip: ip, opened_at: now, wlock: Mutex.new,
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
        seats_housekeeping(now)
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
      return serve_seat(client, head, verb, ip) if head && path == "/room/seat"
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
      if @lock.synchronize { seat_count(claims["slot"]) }.zero?
        @lock.synchronize { @counts["503"] += 1 }
        answer(client, 503)
        return log("rooms: room #{claims['room']} slot #{claims['slot']}: no seats in the router's configuration; " \
                   "answered 503 to #{ip}")
      end
      tls = open_with_seat(conn, key, claims, ip) or return
      [ client, tls.to_io ].each { _1.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil }
      n = @lock.synchronize { @conns.count { _1.room == claims["room"] && !_1.closing } }
      log("rooms: #{conn.label}: open from #{ip} (#{n} in the room), until " \
          "#{Time.at(conn.ends_at).utc.strftime('%Y-%m-%dT%H:%M:%SZ')}")
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pump(conn)
      log("rooms: #{conn.label}: closed from #{ip} after " \
          "#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)} s")
    rescue StandardError => e
      log("rooms: #{e.class}: #{e.message}")
      answer(client, 503) unless conn&.upgraded
    ensure
      @lock.synchronize { @pending -= 1 } if pending
      if conn
        conn.closing = true
        forget(conn)
        @lock.synchronize { touch_seat(conn.room, conn.seat, Time.now.to_f) && save_seats } if conn.seat
      end
      [ conn&.tls, client ].each { _1&.close rescue nil }
    end

    def switch(conn, key)
      accept = Base64.strict_encode64(Digest::SHA1.digest(key + WS_GUID))
      conn.upgraded = true
      conn.client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
    end

    # 101, then the first message decides. Returns the TLS socket to zenohd,
    # or nil (the WebSocket is closed with a code that says why).
    def open_with_seat(conn, key, claims, ip)
      client = conn.client
      slot = claims["slot"]
      switch(conn, key)
      unless client.wait_readable(@seat_wait)
        return refuse_ws(conn, CLOSE_NO_SECRET, "no secret", "no first message within #{@seat_wait} s", ip)
      end
      fin, op, data = ws_read_frame(client)
      case op
      when 0x1
        secret = fin ? self.class.secret_of(data) : nil
        seat = secret && @lock.synchronize { seat_for(claims["room"], secret, Time.now.to_f) }
        return refuse_ws(conn, CLOSE_NO_SEAT, "no seat", "no seat for its secret (POST /room/seat first)", ip) unless seat
        conn.seat = seat
      when 0x2
        return refuse_ws(conn, CLOSE_OLD_PAGE, "this room needs a newer page", "a page without a seat (before 0.3.0)", ip)
      else
        return refuse_ws(conn, 1002, "", "WebSocket opcode #{op} first", ip)
      end
      tls = connect_upstream("room-#{slot}-s#{conn.seat}")
      return refuse_ws(conn, CLOSE_TRY_AGAIN, "zenohd is not there", "zenohd is not there", ip) unless tls
      conn.tls = tls
      if conn.closing
        tls.close rescue nil
        return nil
      end
      tls
    end

    # A page back with its secret (0.3.9, docs/rooms.md "Coming back"): a
    # page takes its seat once when it starts (a page's own sessions, up to
    # 4 on its seat, and its reconnections come without a seat request), so
    # a seat request that finds the secret's seat again comes from a newer
    # page: a tab opened again, or a second tab of the same browser. The
    # connections on that seat belong to the older page (a closed tab's
    # remains, or the other tab) and are cut, so zenohd never has the seat's
    # node from two pages. Their zenohd side closes at once; the page gets a
    # close frame (4403: its seat is no longer its own), and what it still
    # sends is read and dropped until it closes too (LINGER * 2 at most), so
    # nginx sees no reset. Called without the lock.
    def cut_older_page(room, seat)
      older = @lock.synchronize { @conns.select { !_1.closing && _1.room == room && _1.seat == seat } }
      older.each do |c|
        c.closing = true
        c.taken = true
        log("rooms: #{c.label}: closing a connection from #{c.ip} (a newer page took the seat with its secret)")
        begin
          c.tls&.close
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        end
        Thread.new(c) do |old|
          ws_write(old.client, 0x8, [ CLOSE_NO_SEAT ].pack("n") + "taken by a newer page".b, old.wlock)
        rescue IOError, SystemCallError
          nil
        ensure
          sleep LINGER * 2
          old.client&.close rescue nil
        end
      end
      older.size
    end

    def refuse_ws(conn, code, reason, why, ip)
      @lock.synchronize { @counts["ws#{code}"] += 1 }
      ws_write(conn.client, 0x8, [ code ].pack("n") + reason.b, Mutex.new) rescue nil
      linger(conn.client)
      log("rooms: #{conn.label}: refused #{ip}: closed #{code} (#{why})")
      nil
    end

    # Read and drop what the page has already sent (its first batch, its own
    # close frame) before the socket is closed. Closing with unread bytes
    # resets the connection, and nginx logs a reset with the request line:
    # the room's key in its error log.
    def linger(io)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LINGER
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if left <= 0 || !io.wait_readable([ left, LINGER_IDLE ].min)
        io.read_nonblock(4096)
      end
    rescue EOFError, IOError, SystemCallError, IO::WaitReadable
      nil
    end

    # The secret from the first Text ({"s": "<32 hex>"}), or nil.
    def self.secret_of(text)
      s = JSON.parse(text.force_encoding(Encoding::UTF_8))["s"]
      s.is_a?(String) && SECRET.match?(s) ? s : nil
    rescue JSON::ParserError, NoMethodError, TypeError, EncodingError
      nil
    end

    # ---------------------------------------------------------- the seats

    def self.seat_hash(room, secret) = Digest::SHA256.hexdigest("#{room}:#{secret}")

    # POST /room/seat (and its CORS preflight). The body is never logged.
    def serve_seat(client, head, verb, ip)
      return seat_answer(client, 204, nil) if verb == "OPTIONS"
      return seat_answer(client, 405, nil, ip: ip, why: "#{verb} /room/seat") unless verb == "POST"
      return seat_answer(client, 411, nil, ip: ip, why: "no Content-Length") if head.match?(/^Transfer-Encoding:/i)
      len = head[/^Content-Length:\s*(\d+)\s*$/i, 1]
      return seat_answer(client, 411, nil, ip: ip, why: "no Content-Length") unless len
      return seat_answer(client, 400, nil, ip: ip, why: "a #{len}-byte body") if len.to_i > BODY_MAX
      body = read_body(client, len.to_i)
      data = begin
        body && JSON.parse(body.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError, EncodingError
        nil
      end
      token = data.is_a?(Hash) ? data["t"] : nil
      secret = data.is_a?(Hash) ? data["s"] : nil
      unless token.is_a?(String) && secret.is_a?(String) && SECRET.match?(secret)
        return seat_answer(client, 400, nil, ip: ip, why: "no key and secret in the body")
      end
      reload_rooms
      now = Time.now.to_f
      again = nil
      code, out, why, quiet = @lock.synchronize do
        claims, c, w, q = check_key(token, ip, now)
        next [ c, nil, w, q ] unless claims
        n = seat_count(claims["slot"])
        next [ 404, { "error" => "no seats" }, "room #{claims['room']} slot #{claims['slot']} has no seats" ] if n.zero?
        seat, how = assign_seat(claims, secret, n, now)
        next [ 409, { "error" => "full" }, "room #{claims['room']}: all #{n} seats are taken" ] unless seat
        again = [ claims["room"], seat ] if how == "again"
        [ 200, { "node" => "#{@rooms['prefix']}#{claims['slot']}#{seat}", "seat" => seat },
          "room #{claims['room']} slot #{claims['slot']} seat #{seat} (#{how})" ]
      end
      # The older page's connections go before the newer page has its answer.
      cut_older_page(*again) if again
      seat_answer(client, code, out, ip: ip, why: why, quiet: quiet)
    end

    def read_body(io, len)
      body = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @head_seconds
      while body.bytesize < len
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if left <= 0 || !io.wait_readable(left)
        body << io.readpartial(len - body.bytesize)
      end
      body
    rescue EOFError, IOError, SystemCallError
      nil
    end

    # The answer to a seat request: JSON (or nothing), for any origin (the
    # page is on another name than the router; no cookie is involved).
    def seat_answer(client, code, data, ip: nil, why: nil, quiet: false)
      body = data ? JSON.generate(data) : ""
      client.write("HTTP/1.1 #{code} #{STATUS[code]}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nCache-Control: no-store\r\n" \
                   "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\n" \
                   "Access-Control-Allow-Headers: Content-Type\r\nAccess-Control-Max-Age: 600\r\n" \
                   "Connection: close\r\n\r\n#{body}")
      return if code == 204
      @lock.synchronize { @counts["seat_#{code}"] += 1 }
      return if quiet
      log(code == 200 ? "rooms: #{why}: for a page from #{ip}" : "rooms: refused a seat to #{ip}: #{code} (#{why})")
    rescue IOError, SystemCallError
      nil
    end

    # A seat for the secret in the room (under the lock): [seat, how] or
    # nil when every seat is taken.
    def assign_seat(claims, secret, n, now)
      room = claims["room"]
      entry = (@seats[room] ||= { "slot" => claims["slot"], "until" => claims["exp"], "seats" => {} })
      h = self.class.seat_hash(room, secret)
      seats = entry["seats"]
      if (got = seats[h]) && got["seat"].to_i.between?(1, n)
        got["at"] = now
        save_seats
        return [ got["seat"], "again" ]
      end
      taken = seats.values.map { _1["seat"] }
      seat = (1..n).map { format("%02d", _1) }.find { !taken.include?(_1) }
      how = "new"
      unless seat
        live = @conns.reject(&:closing).select { _1.room == room }.map(&:seat)
        old_h, old = seats.reject { |_, v| live.include?(v["seat"]) || now - v["at"].to_f < @seat_idle }
                          .min_by { |_, v| v["at"].to_f }
        return nil unless old_h
        seats.delete(old_h)
        seat = old["seat"]
        how = "given again: nobody on it for #{((now - old['at'].to_f) / 60).round} min"
      end
      seats[h] = { "seat" => seat, "at" => now }
      save_seats
      [ seat, how ]
    end

    # The seat of the secret in the room, touched (under the lock), or nil.
    def seat_for(room, secret, now)
      entry = @seats[room] or return nil
      got = entry["seats"][self.class.seat_hash(room, secret)] or return nil
      return nil unless got["seat"].to_i.between?(1, seat_count(entry["slot"]))
      got["at"] = now
      save_seats
      got["seat"]
    end

    def touch_seat(room, seat, now)
      got = @seats.dig(room, "seats")&.values&.find { _1["seat"] == seat } or return false
      got["at"] = now
      true
    end

    # On the watch: a room that is over loses its seats (only when the
    # rooms' file reads: a broken file is not a closed room); a seat with a
    # connection is touched every TOUCH_EVERY seconds, so a door started
    # again knows it was in use.
    def seats_housekeeping(now)
      @lock.synchronize do
        dirty = false
        if @rooms["ok"]
          @seats.keys.each do |room|
            next if room_open?(room, @seats[room]["slot"], now)
            n = @seats.delete(room)["seats"].size
            dirty = true
            log("rooms: room #{room}: its #{n} seat(s) are cleared (the room is over)")
          end
        end
        if now - @touched_at >= TOUCH_EVERY
          @touched_at = now
          @conns.reject(&:closing).each { |c| dirty = true if c.seat && touch_seat(c.room, c.seat, now) }
        end
        save_seats if dirty
      end
    end

    def load_seats
      return unless @seats_file && File.exist?(@seats_file)
      data = JSON.parse(File.read(@seats_file))
      rooms = data["rooms"]
      raise TypeError unless rooms.is_a?(Hash)
      @seats = rooms.select do |room, e|
        room.match?(RoomToken::ROOM) && e.is_a?(Hash) && e["slot"].to_s.match?(RoomToken::SLOT) && e["seats"].is_a?(Hash)
      end
      log("rooms: read #{@seats_file}: #{@seats.size} room(s) with seats")
    rescue JSON::ParserError, SystemCallError, TypeError, NoMethodError => e
      @seats = {}
      log("rooms: #{@seats_file} is unreadable (#{e.class}): starting with no seats taken")
    end

    # Writes the seats' table (under the lock). Only hashes, never a secret.
    def save_seats
      return true unless @seats_file
      tmp = "#{@seats_file}.tmp"
      File.write(tmp, JSON.generate({ "format" => 1, "rooms" => @seats }))
      File.chmod(0o600, tmp)
      File.rename(tmp, @seats_file)
      @seats_ok = true
    rescue SystemCallError => e
      log("rooms: cannot write #{@seats_file} (#{e.class}): the seats are kept in memory only") if @seats_ok
      @seats_ok = false
      true
    end

    # The TLS context for a seat's certificate in the rooms' directory
    # (room-<slot>-s<seat>).
    def context(name)
      cert_file = File.join(@certs_dir, "#{name}.pem")
      mtime = File.mtime(cert_file)
      cached = @contexts[name]
      return cached[1] if cached && cached[0] == mtime
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(cert_file))
      ctx.key = OpenSSL::PKey.read(File.read(File.join(@certs_dir, "#{name}.key")))
      ctx.ca_file = File.join(@certs_dir, "ca.pem")
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.verify_hostname = true
      @contexts[name] = [ mtime, ctx ]
      ctx
    end

    def connect_upstream(name)
      tcp = Socket.tcp(*split_hostport(@upstream), connect_timeout: 3)
      tls = OpenSSL::SSL::SSLSocket.new(tcp, context(name))
      tls.hostname = @tls_name
      tls.sync_close = true
      tls.connect
      tls
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError, SocketError => e
      log("rooms: #{name}: no TLS link to #{@upstream} (#{e.class}: #{e.message})")
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

    def pump(conn)
      client = conn.client
      tls = conn.tls
      wlock = conn.wlock
      up = Thread.new do # browser -> zenohd
        msg = +""
        loop do
          fin, op, data = ws_read_frame(client)
          case op
          when 0x2, 0x0
            next if conn.taken # cut for a newer connection: read and dropped
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
        log("rooms: #{conn.label}: from the browser: #{e.message}") unless conn.closing || e.is_a?(EOFError)
        linger(client) if conn.taken && !e.is_a?(EOFError)
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
