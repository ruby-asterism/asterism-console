require "test_helper"
require "tmpdir"
require "socket"
require "securerandom"

# The rooms' door (Relay::RoomDoor) between a WebSocket client and a stand-in
# for zenohd's mutual-TLS listener that counts every connection and byte it
# gets: nothing reaches it before a key checks, the framing both ways, the
# InitAck rewrite, the limits, and the cuts (a key's end, a closed room, a
# slot given to another room).
class Relay::RoomDoorTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # zenohd's stand-in: TLS with client certificates from the CA; it sends an
  # InitAck-shaped batch first, then echoes every batch it gets.
  class Upstream
    attr_reader :port, :accepts, :bytes, :names

    def initialize(dir)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(File.join(dir, "zenohd-test.pem")))
      ctx.key = OpenSSL::PKey.read(File.read(File.join(dir, "zenohd-test.key")))
      ctx.ca_file = File.join(dir, "ca.pem")
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @accepts = 0
      @bytes = 0
      @names = []
      @lock = Mutex.new
      @thread = Thread.new do
        loop do
          sock = @tcp.accept
          @lock.synchronize { @accepts += 1 }
          Thread.new(sock) { |s| serve(s, ctx) }
        end
      rescue IOError
        nil
      end
    end

    # 0x61: InitAck (0x01) + A (0x20) + S (0x40); version 9; zid of 16
    # bytes (0xf0); resolution 0x0a, batch 65535; a cookie.
    INIT_ACK = ([ 0x61, 0x09, 0xf0 ] + Array.new(16, 0xab) + [ 0x0a, 0xff, 0xff, 0x01, 0x02 ]).pack("C*").freeze

    def serve(sock, ctx)
      tls = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      tls.sync_close = true
      tls.accept
      cn = tls.peer_cert.subject.to_a.find { _1[0] == "CN" }&.dig(1)
      @lock.synchronize { @names << cn }
      tls.write([ INIT_ACK.bytesize ].pack("v") + INIT_ACK)
      loop do
        len = tls.read(2) or break
        n = len.unpack1("v")
        batch = tls.read(n)
        @lock.synchronize { @bytes += 2 + n }
        tls.write([ n ].pack("v") + batch)
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      tls&.close rescue nil
    end

    def close
      @tcp.close rescue nil
      @thread.kill
    end
  end

  # A minimal WebSocket client (masked frames, as a browser sends).
  class Client
    attr_reader :status, :sock

    def initialize(port, token, path: "/room", ip: nil)
      @sock = TCPSocket.new("127.0.0.1", port)
      q = token ? "?t=#{URI.encode_www_form_component(token)}" : ""
      head = "GET #{path}#{q} HTTP/1.1\r\nHost: router.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
             "Sec-WebSocket-Key: #{[ SecureRandom.bytes(16) ].pack('m0')}\r\nSec-WebSocket-Version: 13\r\n"
      head += "X-Forwarded-For: #{ip}\r\n" if ip
      @sock.write(head + "\r\n")
      line = @sock.gets("\r\n").to_s
      @status = line.split(" ")[1].to_i
      nil while (h = @sock.gets("\r\n")) && h != "\r\n"
    end

    def frame(data, opcode: 0x2, fin: true)
      mask = SecureRandom.bytes(4)
      n = data.bytesize
      len = n < 126 ? [ 0x80 | n ].pack("C") : (n < 65_536 ? [ 0x80 | 126, n ].pack("Cn") : [ 0x80 | 127, n ].pack("CQ>"))
      masked = data.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i & 3) }.pack("C*")
      @sock.write([ (fin ? 0x80 : 0) | opcode ].pack("C") + len + mask + masked)
    end

    def read_message(timeout = 3)
      return nil unless @sock.wait_readable(timeout)
      b0, b1 = @sock.read(2)&.unpack("CC")
      return nil unless b1
      len = b1 & 0x7f
      len = case len
      when 126 then @sock.read(2).unpack1("n")
      when 127 then @sock.read(8).unpack1("Q>")
      else len
      end
      [ b0 & 0x0f, @sock.read(len) ]
    rescue IOError, SystemCallError
      nil
    end

    # Whether the door closes it within timeout (what is still to be read
    # is read and dropped).
    def closed?(timeout = 3)
      deadline = Time.now + timeout
      loop do
        left = deadline - Time.now
        return false if left <= 0
        next unless @sock.wait_readable(left)
        begin
          @sock.read_nonblock(65_536)
        rescue IO::WaitReadable
          nil
        end
      end
    rescue EOFError, Errno::ECONNRESET
      true
    end

    # How the door ends the connection: :eof, :reset or :open (timeout).
    def ending(timeout = 4)
      deadline = Time.now + timeout
      loop do
        left = deadline - Time.now
        return :open if left <= 0
        next unless @sock.wait_readable(left)
        begin
          @sock.read_nonblock(65_536)
        rescue IO::WaitReadable
          nil
        end
      end
    rescue EOFError
      :eof
    rescue Errno::ECONNRESET
      :reset
    end

    def close
      @sock.close rescue nil
    end
  end

  setup do
    @dir = Dir.mktmpdir
    ca = Relay::CertAuthority.create(@dir)
    ca.issue("zenohd-test", dns: %w[localhost])
    %w[room-01 room-02 room-01-s01 room-01-s02 room-02-s01].each { ca.issue(_1) }
    @key = OpenSSL::PKey.generate_key("ED25519")
    @kid = Relay::RoomToken.kid(@key)
    @rooms_file = File.join(@dir, "rooms.json")
    @room_a = SecureRandom.hex(8)
    @room_b = SecureRandom.hex(8)
    write_rooms({ "01" => [ @room_a, 16 ], "02" => [ @room_b, 16 ] })
    @upstream = Upstream.new(@dir)
    @logs = []
    @door = Relay::RoomDoor.new(listen: "127.0.0.1:0", upstream: "127.0.0.1:#{@upstream.port}", tls_name: "localhost",
                                rooms_file: @rooms_file, certs_dir: @dir, status_listen: "127.0.0.1:0", total: 5,
                                head_seconds: 1, log: ->(m) { @logs << m }).start
    @clients = []
  end

  teardown do
    @clients&.each(&:close)
    @door&.stop
    @seat_door&.stop
    @upstream&.close
    FileUtils.rm_rf(@dir)
  end

  def write_rooms(slots, revoked: [], keys: [ @key ])
    data = { "format" => 1, "keys" => keys.map { { "kid" => Relay::RoomToken.kid(_1), "public_key" => _1.public_to_pem } },
             "slots" => slots.transform_values { |room, max, seats| { "room" => room, "until" => Time.now.to_i + 3600, "max" => max,
                                                                       "seats" => seats.to_i } },
             "seat_node_prefix" => "wasm-", "hosts" => [ "games" ],
             "revoked" => revoked.map { { "room" => _1, "until" => Time.now.to_i + 3600 } } }
    tmp = "#{@rooms_file}.tmp"
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, @rooms_file)
    # The door reads it again when its time stamp changes.
    t = Time.now + rand(1000)
    File.utime(t, t, @rooms_file)
  end

  def token(room: @room_a, slot: "01", exp: Time.now.to_i + 3600, max: 16, key: @key)
    Relay::RoomToken.sign(key, { "v" => 1, "kid" => Relay::RoomToken.kid(key), "room" => room, "slot" => slot,
                                 "exp" => exp, "max" => max, "jti" => SecureRandom.uuid })
  end

  def client(tok, **opts)
    Client.new(@door.listen_port, tok, **opts).tap { @clients << _1 }
  end

  def wait_until(seconds = 3)
    deadline = Time.now + seconds
    sleep 0.05 until yield || Time.now > deadline
    yield
  end

  test "nothing reaches zenohd before a key checks" do
    good = token
    tampered = good.dup
    tampered[12] = tampered[12] == "A" ? "B" : "A"
    other = token(key: OpenSSL::PKey.generate_key("ED25519"))
    cases = { "no key" => nil, "garbage" => "abc", "two dots" => "a.b.c", "tampered" => tampered,
              "another signer" => other, "ended" => token(exp: Time.now.to_i - 5),
              "past the cap" => token(exp: Time.now.to_i + 30 * 3600) }
    cases.each do |what, tok|
      c = client(tok)
      assert_includes [ 403, 410 ], c.status, what
    end
    assert_equal 400, client(good, path: "/").status, "only /room"
    s = TCPSocket.new("127.0.0.1", @door.listen_port) # no head at all: dropped after head_seconds
    @clients << Struct.new(:sock) { def close = sock.close }.new(s)
    sleep 1.3
    assert_equal 0, @upstream.accepts, "no connection to zenohd for a key that does not check"
    assert_equal 0, @upstream.bytes
    assert(@logs.none? { _1.include?(good) || _1.include?(tampered) }, "the key is never logged")
  end

  test "a good key: 101, the slot's certificate, InitAck lowered by 2, batches both ways" do
    c = client(token)
    assert_equal 101, c.status
    op, ack = c.read_message
    assert_equal 0x2, op
    at = 3 + 16
    assert_equal 65_533, ack.byteslice(at + 1, 2).unpack1("v"), "batch size 65535 -> 65533"
    assert_equal [ "room-01" ], @upstream.names
    c.frame("hello zenoh".b)
    assert_equal [ 0x2, "hello zenoh".b ], c.read_message
    big = SecureRandom.bytes(60_000)
    c.frame(big.byteslice(0, 30_000), fin: false)
    c.frame(big.byteslice(30_000, 30_000), opcode: 0x0)
    assert_equal [ 0x2, big ], c.read_message, "a fragmented message is one batch"
    c.frame("ping".b, opcode: 0x9)
    assert_equal [ 0xA, "ping".b ], c.read_message
    assert_equal({ @room_a => 1 }, @door.status["rooms"])
  end

  test "every frame length reads right, 127 and 126 among them (16-bit lengths)" do
    c = client(token)
    c.read_message # the InitAck
    [ 125, 126, 127, 128, 200, 65_535 - 2 ].each do |n|
      data = SecureRandom.bytes(n)
      c.frame(data)
      assert_equal [ 0x2, data ], c.read_message, "a #{n}-byte message"
    end
  end

  test "too large a message closes the connection" do
    c = client(token)
    assert_equal 101, c.status
    c.read_message
    c.frame(SecureRandom.bytes(65_536))
    assert c.closed?
  end

  test "limits: the key's (the room's) and the door's" do
    two = token(max: 2)
    assert_equal [ 101, 101, 503 ], 3.times.map { client(two).status }
    assert_equal [ 101, 101, 101, 503 ], [ client(token(room: @room_b, slot: "02")).status,
                                           client(token(room: @room_b, slot: "02")).status,
                                           client(token(room: @room_b, slot: "02")).status,
                                           client(token(room: @room_b, slot: "02")).status ], "5 at most in all"
    assert_equal 5, @door.status["total"]
  end

  test "closing a room cuts its connections and refuses its keys" do
    tok = token
    a = client(tok)
    b = client(token(room: @room_b, slot: "02"))
    assert_equal [ 101, 101 ], [ a.status, b.status ]
    write_rooms({ "02" => [ @room_b, 16 ] }, revoked: [ @room_a ])
    t0 = Time.now
    assert a.closed?(3), "room A's connection is cut"
    assert_operator Time.now - t0, :<, 2
    refute b.closed?(0.6), "room B stays"
    assert_equal 410, client(tok).status, "and its key is refused"
  end

  test "a slot given to another room: the old room's connections go first" do
    old = client(token)
    assert_equal 101, old.status
    room_c = SecureRandom.hex(8)
    write_rooms({ "01" => [ room_c, 16 ], "02" => [ @room_b, 16 ] })
    sleep 0.05
    fresh = client(token(room: room_c))
    assert_equal 101, fresh.status
    assert old.closed?(1), "the old room is cut when the new one comes in (or by the watch)"
    assert wait_until { @door.status["slots"] == { "01" => 1 } }
    assert_equal({ room_c => 1 }, @door.status["rooms"])
  end

  test "keys that do not check are limited per address; a good key still gets in" do
    (Relay::RoomDoor::BAD_LIMIT + 2).times { client("x.y", ip: "198.51.100.7").close }
    assert_equal 429, client("x.y", ip: "198.51.100.7").status
    assert_equal 403, client("x.y", ip: "198.51.100.8").status, "another address"
    assert_equal 101, client(token, ip: "198.51.100.7").status, "a key that checks is not limited"
  end

  test "no rooms' file: no room" do
    File.delete(@rooms_file)
    sleep 0.7
    assert_includes [ 403, 410 ], client(token).status
    assert_equal 0, @upstream.accepts
  end

  test "the status port" do
    client(token)
    res = Net::HTTP.get_response(URI("http://127.0.0.1:#{@door.status_port}/status"))
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal [ 1, 5 ], body.values_at("total", "limit")
  end

  # ------------------------------------------------------------ seats (0.3.0)

  SECRET_A = "a1" * 16
  SECRET_B = "b2" * 16
  SECRET_C = "c3" * 16

  # A door whose slot 01 has 2 seats (slot 02 none), its own seats' file.
  def seat_door(**opts)
    write_rooms({ "01" => [ @room_a, 16, 2 ], "02" => [ @room_b, 16 ] })
    @seats_file ||= File.join(@dir, "seats.json")
    @seat_door = Relay::RoomDoor.new(listen: "127.0.0.1:0", upstream: "127.0.0.1:#{@upstream.port}", tls_name: "localhost",
                                     rooms_file: @rooms_file, certs_dir: @dir, total: 10, head_seconds: 1,
                                     seats_file: @seats_file, seat_wait: 1, log: ->(m) { @logs << m }, **opts).start
  end

  # POST /room/seat: [status, body (parsed), the raw answer].
  def seat(tok, secret, door: @seat_door, body: nil, ip: nil, verb: "POST")
    s = TCPSocket.new("127.0.0.1", door.listen_port)
    body ||= JSON.generate({ "t" => tok, "s" => secret })
    head = "#{verb} /room/seat HTTP/1.1\r\nHost: router.test\r\nContent-Type: text/plain\r\n" \
           "Content-Length: #{body.bytesize}\r\nOrigin: https://play.test\r\n"
    head += "X-Forwarded-For: #{ip}\r\n" if ip
    s.write(head + "\r\n" + body)
    raw = s.read
    code = raw[/\AHTTP\/1.1 (\d+)/, 1].to_i
    text = raw.split("\r\n\r\n", 2)[1].to_s
    [ code, text.empty? ? nil : JSON.parse(text), raw ]
  ensure
    s&.close
  end

  def seat_client(tok, secret, door: @seat_door)
    c = Client.new(door.listen_port, tok).tap { @clients << _1 }
    c.frame(JSON.generate({ "s" => secret }), opcode: 0x1) if secret
    c
  end

  # The close code of a WebSocket the door closed (nil: not closed).
  def close_code(c)
    loop do
      op, data = c.read_message(2)
      return nil unless op
      return data.unpack1("n") if op == 0x8
    end
  end

  test "a seat: the same secret the same seat, another secret another, then 409" do
    seat_door
    tok = token
    code, a, raw = seat(tok, SECRET_A)
    assert_equal [ 200, { "node" => "wasm-0101", "seat" => "01" } ], [ code, a ]
    assert_includes raw, "Access-Control-Allow-Origin: *"
    assert_includes raw, "Cache-Control: no-store"
    assert_equal [ 200, { "node" => "wasm-0101", "seat" => "01" } ], seat(token, SECRET_A).first(2), "another link, same seat"
    assert_equal [ 200, { "node" => "wasm-0102", "seat" => "02" } ], seat(tok, SECRET_B).first(2)
    assert_equal [ 409, { "error" => "full" } ], seat(tok, SECRET_C).first(2)
    assert_equal({ @room_a => 2 }, @seat_door.status["seats"])
    assert_equal 0, @upstream.accepts, "taking a seat connects nothing"
  end

  test "a seat request is checked like a key; a slot without seats says so" do
    seat_door
    assert_equal 403, seat("x.y", SECRET_A).first
    assert_equal 410, seat(token(exp: Time.now.to_i - 5), SECRET_A).first
    assert_equal 400, seat(token, "short").first
    assert_equal 400, seat(nil, nil, body: "{not json #{SECRET_A}").first
    # Answered 400 without reading the body (the client may see the reset
    # first; nginx refuses such a body itself, client_max_body_size 2k).
    big = begin
      seat(nil, nil, body: "x" * 3000).first
    rescue Errno::ECONNRESET, Errno::EPIPE
      0
    end
    assert_includes [ 400, 0 ], big
    assert_equal [ 404, { "error" => "no seats" } ], seat(token(room: @room_b, slot: "02"), SECRET_A).first(2)
    assert_equal 204, seat(nil, nil, verb: "OPTIONS", body: "").first, "the CORS preflight"
    assert_equal 405, seat(nil, nil, verb: "GET", body: "").first
  end

  test "the WebSocket of a room with seats: the secret first, then the seat's certificate" do
    seat_door
    tok = token
    seat(tok, SECRET_A)
    c = seat_client(tok, SECRET_A)
    assert_equal 101, c.status
    op, = c.read_message
    assert_equal 0x2, op, "the InitAck"
    assert_equal [ "room-01-s01" ], @upstream.names
    c.frame("hello".b)
    assert_equal [ 0x2, "hello".b ], c.read_message
    d = seat_client(tok, SECRET_A)
    d.read_message
    assert_equal [ "room-01-s01", "room-01-s01" ], @upstream.names, "a page's second session, the same seat"
    assert_equal({ @room_a => 2 }, @seat_door.status["rooms"])
  end

  test "no seat, no secret, an old page: closed, and nothing reaches zenohd" do
    seat_door
    tok = token
    c = seat_client(tok, SECRET_B)
    assert_equal 101, c.status
    assert_equal Relay::RoomDoor::CLOSE_NO_SEAT, close_code(c), "a secret without a seat"
    old = seat_client(tok, nil)
    old.frame("\x01\x02InitSyn".b)
    assert_equal Relay::RoomDoor::CLOSE_OLD_PAGE, close_code(old), "a page before 0.3.0 (Binary first)"
    quiet = seat_client(tok, nil)
    assert_equal Relay::RoomDoor::CLOSE_NO_SECRET, close_code(quiet), "nothing within seat_wait"
    bad = seat_client(tok, nil)
    bad.frame("not json", opcode: 0x1)
    assert_equal Relay::RoomDoor::CLOSE_NO_SEAT, close_code(bad)
    assert_equal 0, @upstream.accepts
  end

  test "a refusal reads what the page had sent first, so it ends with no reset (nginx logs resets)" do
    # zenohd answers slowly and then not at all (1013): the page's first batch
    # comes in meanwhile and is still unread when the door gives up.
    slow = TCPServer.new("127.0.0.1", 0)
    Thread.new { loop { c = slow.accept; Thread.new { sleep 0.3; c.close } } rescue nil }
    write_rooms({ "01" => [ @room_a, 16, 2 ], "02" => [ @room_b, 16 ] })
    @seat_door = Relay::RoomDoor.new(listen: "127.0.0.1:0", upstream: "127.0.0.1:#{slow.addr[1]}", tls_name: "localhost",
                                     rooms_file: @rooms_file, certs_dir: @dir, total: 10, head_seconds: 1,
                                     seats_file: File.join(@dir, "seats.json"), seat_wait: 1, log: ->(m) { @logs << m }).start
    tok = token
    assert_equal 200, seat(tok, SECRET_A).first
    c = seat_client(tok, SECRET_A)
    sleep 0.05
    c.frame("\x01\x02InitSyn".b) # the page's first batch, right behind its secret
    assert_equal Relay::RoomDoor::CLOSE_TRY_AGAIN, close_code(c)
    c.frame([ 1000 ].pack("n"), opcode: 0x8) # the page's own close
    assert_equal :eof, c.ending
  ensure
    slow&.close
  end

  test "legacy_slot: an old page gets in with the slot's certificate, its first batch goes on" do
    seat_door(legacy_slot: true)
    old = seat_client(token, nil)
    old.frame("InitSyn".b)
    op, = old.read_message
    assert_equal 0x2, op
    assert_equal [ 0x2, "InitSyn".b ], old.read_message, "the stand-in echoes the first batch"
    assert_equal [ "room-01" ], @upstream.names
  end

  test "a slot without seats works as before 0.3.0" do
    seat_door
    c = client(token(room: @room_b, slot: "02"))
    assert_equal 101, c.status
    c.read_message
    assert_equal [ "room-02" ], @upstream.names
  end

  test "a seat nobody is on for seat_idle goes to a new secret; a seat in use does not" do
    seat_door(seat_idle: 0.6)
    tok = token
    seat(tok, SECRET_A)
    seat(tok, SECRET_B)
    a = seat_client(tok, SECRET_A)
    a.read_message
    sleep 0.8
    assert_equal [ 200, { "node" => "wasm-0102", "seat" => "02" } ], seat(tok, SECRET_C).first(2),
                 "B's seat (no connection for 0.8 s), not A's (connected)"
    assert_equal 409, seat(tok, SECRET_B).first, "B now has none, and A's is in use"
    a.close
    assert wait_until { @seat_door.status["total"].zero? }
    assert_equal 409, seat(tok, SECRET_B).first, "A just left"
    sleep 0.8
    code, got = seat(tok, SECRET_B)
    assert_equal 200, code, "both idle now: the one idle longest (C's, never used) goes to B"
    assert_equal "wasm-0102", got["node"]
  end

  test "the seats outlive the door, end with their room, and hold no secret" do
    seat_door
    tok = token
    seat(tok, SECRET_A)
    seat(tok, SECRET_B)
    @seat_door.stop
    seat_door
    assert_equal [ 200, { "node" => "wasm-0102", "seat" => "02" } ], seat(tok, SECRET_B).first(2), "after a restart"
    text = File.read(@seats_file)
    assert_equal "600", format("%o", File.stat(@seats_file).mode & 0o777)
    [ SECRET_A, SECRET_B ].each { refute_includes text, _1 }
    write_rooms({ "02" => [ @room_b, 16 ] }, revoked: [ @room_a ])
    assert wait_until { @seat_door.status["seats"].empty? }, "a closed room's seats are cleared"
    refute_includes File.read(@seats_file), @room_a
    # The logs: neither the secrets, their hashes, nor the key.
    hashes = [ SECRET_A, SECRET_B, SECRET_C ].map { Relay::RoomDoor.seat_hash(@room_a, _1) }
    (([ SECRET_A, SECRET_B, SECRET_C, tok ] + hashes)).each do |x|
      assert(@logs.none? { _1.include?(x) }, "never logged")
    end
  end

  test "a broken rooms' file clears no seat" do
    seat_door
    seat(token, SECRET_A)
    File.write(@rooms_file, "{broken")
    t = Time.now + 5000
    File.utime(t, t, @rooms_file)
    sleep 1.2
    assert_equal({ @room_a => 1 }, @seat_door.status["seats"])
  end
end
