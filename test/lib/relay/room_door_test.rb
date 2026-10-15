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

    def close
      @sock.close rescue nil
    end
  end

  setup do
    @dir = Dir.mktmpdir
    ca = Relay::CertAuthority.create(@dir)
    ca.issue("zenohd-test", dns: %w[localhost])
    %w[room-01 room-02].each { ca.issue(_1) }
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
    @upstream&.close
    FileUtils.rm_rf(@dir)
  end

  def write_rooms(slots, revoked: [], keys: [ @key ])
    data = { "format" => 1, "keys" => keys.map { { "kid" => Relay::RoomToken.kid(_1), "public_key" => _1.public_to_pem } },
             "slots" => slots.transform_values { |room, max| { "room" => room, "until" => Time.now.to_i + 3600, "max" => max } },
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
end
