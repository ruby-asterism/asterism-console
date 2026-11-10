require "test_helper"
require "tmpdir"
require "socket"
require "securerandom"
require "open3"

# The pass door's browsers with a certificate (T8, bin/ws_door with
# Relay::BrowserDoor), run as its own process between a WebSocket client
# (as nginx hands it on, with the console's word) and two stand-ins: zenohd's
# mutual-TLS listener (which names the certificate it got) and its ws/
# listener (plain bytes). Which way a page goes, the console's signature,
# one page per name, the notice and the framing.
class Relay::BrowserDoorTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  INIT_ACK = ([ 0x61, 0x09, 0xf0 ] + Array.new(16, 0xab) + [ 0x0a, 0xff, 0xff, 0x01, 0x02 ]).pack("C*").freeze

  # zenohd's tls/: an InitAck-shaped batch first, then every batch echoed.
  class TlsUpstream
    attr_reader :port, :names

    def initialize(dir)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(File.join(dir, "zenohd-test.pem")))
      ctx.key = OpenSSL::PKey.read(File.read(File.join(dir, "zenohd-test.key")))
      ctx.ca_file = File.join(dir, "ca.pem")
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @names = Queue.new
      @thread = Thread.new do
        loop { Thread.new(@tcp.accept) { |s| serve(s, ctx) } }
      rescue IOError
        nil
      end
    end

    def serve(sock, ctx)
      tls = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      tls.sync_close = true
      tls.accept
      @names << tls.peer_cert.subject.to_a.find { _1[0] == "CN" }&.dig(1)
      tls.write([ INIT_ACK.bytesize ].pack("v") + INIT_ACK)
      loop do
        len = tls.read(2) or break
        batch = tls.read(len.unpack1("v"))
        tls.write([ batch.bytesize ].pack("v") + batch)
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

  # zenohd's ws/: answers the upgrade, then echoes the bytes; keeps the heads.
  class WsUpstream
    attr_reader :port, :heads

    def initialize
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @heads = Queue.new
      @thread = Thread.new do
        loop do
          Thread.new(@tcp.accept) do |s|
            head = +""
            head << s.readpartial(1) until head.end_with?("\r\n\r\n")
            @heads << head
            s.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                    "Sec-WebSocket-Accept: x\r\n\r\n")
            loop { s.write(s.readpartial(4096)) }
          rescue IOError, SystemCallError
            nil
          ensure
            s.close rescue nil
          end
        end
      rescue IOError
        nil
      end
    end

    def close
      @tcp.close rescue nil
      @thread.kill
    end
  end

  setup do
    @dir = Dir.mktmpdir
    @env = { "ASTERISM_ROOMS_DIR" => File.join(@dir, "rooms") }
    @browsers = Relay::BrowserCerts.dir(@env)
    FileUtils.mkdir_p(@browsers)
    ca = Relay::CertAuthority.create(File.join(@dir, "ca"))
    ca.issue("zenohd-test", dns: %w[localhost])
    %w[wasm-alice wasm-bob].each { ca.issue(_1) }
    %w[ca.pem zenohd-test.pem zenohd-test.key].each { FileUtils.cp(File.join(@dir, "ca", _1), @dir) }
    %w[ca.pem wasm-alice.pem wasm-alice.key wasm-bob.pem wasm-bob.key].each { FileUtils.cp(File.join(@dir, "ca", _1), @browsers) }
    File.write(File.join(@browsers, "browsers.json"), JSON.generate({ "format" => 1, "nodes" => [ "wasm-alice" ] }))
    @tls = TlsUpstream.new(@dir)
    @ws = WsUpstream.new
    @port = free_port
    env = { "WS_DOOR_LISTEN" => "127.0.0.1:#{@port}", "WS_DOOR_UPSTREAM" => "127.0.0.1:#{@ws.port}",
            "WS_DOOR_BROWSERS_DIR" => @browsers, "WS_DOOR_BROWSER_UPSTREAM" => "127.0.0.1:#{@tls.port}",
            "WS_DOOR_BROWSER_TLS_NAME" => "localhost", "WS_DOOR_ROOM_LISTEN" => "" }
    @in, @out, @door = Open3.popen2e(env, RbConfig.ruby, Rails.root.join("bin/ws_door").to_s)
    @log = +""
    @reader = Thread.new { @out.each_line { @log << _1 } rescue nil }
    wait_for { @log.include?("listening on") }
    @socks = []
  end

  teardown do
    @socks&.each { _1.close rescue nil }
    Process.kill("TERM", @door.pid) rescue nil
    @door&.join(3)
    @reader&.kill
    @in&.close rescue nil
    @tls&.close
    @ws&.close
    FileUtils.rm_rf(@dir)
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1].tap { s.close }
  end

  def wait_for(seconds = 5)
    deadline = Time.now + seconds
    sleep 0.05 until yield || Time.now > deadline
    assert yield, "waited #{seconds} s; the door's log:\n#{@log}"
  end

  def word(node, pass: 7, notice: true)
    Relay::BrowserCerts.door_word(node: node, pass: pass, notice: notice, until_at: Time.now + 3600, env: @env)
  end

  # A page as nginx hands it on: [socket, status].
  def page(word)
    s = TCPSocket.new("127.0.0.1", @port)
    @socks << s
    head = "GET / HTTP/1.1\r\nHost: router.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Key: #{[ SecureRandom.bytes(16) ].pack('m0')}\r\nSec-WebSocket-Version: 13\r\n" \
           "X-Forwarded-For: 192.0.2.7\r\n"
    head += "X-Asterism-Browser: #{word}\r\n" if word
    s.write(head + "\r\n")
    status = s.gets("\r\n").to_s.split(" ")[1].to_i
    nil while (h = s.gets("\r\n")) && h != "\r\n"
    [ s, status ]
  end

  def read_frame(s, timeout = 3)
    return nil unless s.wait_readable(timeout)
    b0, b1 = s.read(2).unpack("CC")
    len = b1 & 0x7f
    len = s.read(2).unpack1("n") if len == 126
    [ b0 & 0x0f, s.read(len) ]
  end

  def send_binary(s, data)
    mask = SecureRandom.bytes(4)
    masked = data.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i & 3) }.pack("C*")
    s.write([ 0x82, 0x80 | data.bytesize ].pack("CC") + mask + masked)
  end

  test "the user's own page goes to tls/ with its certificate, is told so, and its batches are framed" do
    s, status = page(word("wasm-alice"))
    assert_equal 101, status
    assert_equal "wasm-alice", @tls.names.pop(timeout: 3)
    op, text = read_frame(s)
    assert_equal 0x1, op
    assert_equal({ "door" => { "verified" => true, "node" => "wasm-alice" } }, JSON.parse(text))
    op, batch = read_frame(s)
    assert_equal 0x2, op
    assert_equal 65_533, batch.byteslice(20, 2).unpack1("v"), "InitAck's batch size lowered by 2"
    send_binary(s, "hello")
    assert_equal [ 0x2, "hello" ], read_frame(s)
    assert @ws.heads.empty?, "nothing to ws/"
    wait_for { @log.include?("as wasm-alice with its certificate") }
  end

  test "a word that is not the console's counts for nothing: the shared ws/, and no notice" do
    forged = word("wasm-alice").sub(/mac=\h{64}/, "mac=#{'0' * 64}")
    s, status = page(forged)
    assert_equal 101, status
    head = @ws.heads.pop(timeout: 3)
    assert head, "to ws/"
    refute_match(/X-Asterism-Browser/i, head, "the word does not reach zenohd")
    assert @tls.names.empty?
    send_binary(s, "x")
    assert_equal "\x82\x81".b, s.read(2), "zenohd's ws/ bytes come back as they are (no Text before them)"
  end

  test "a name not applied yet, or no name, goes to the shared ws/ and the page is told why" do
    { "wasm-bob" => /not in the router's configuration yet/, "" => /no certificate for this page/ }.each do |node, why|
      s, status = page(word(node))
      assert_equal 101, status
      assert @ws.heads.pop(timeout: 3)
      op, text = read_frame(s)
      assert_equal 0x1, op
      got = JSON.parse(text)["door"]
      assert_equal false, got["verified"]
      assert_match why, got["why"]
    end
    assert @tls.names.empty?
  end

  test "one page per name: another pass is shared while the first is connected; the same pass takes it again" do
    a1, = page(word("wasm-alice", pass: 1))
    assert_equal "wasm-alice", @tls.names.pop(timeout: 3)
    read_frame(a1)
    b, = page(word("wasm-alice", pass: 2))
    _, text = read_frame(b)
    assert_match(/another page is connected as wasm-alice/, JSON.parse(text)["door"]["why"])
    a2, = page(word("wasm-alice", pass: 1))
    assert_equal "wasm-alice", @tls.names.pop(timeout: 3), "the first page's second session"
    _, text = read_frame(a2)
    assert JSON.parse(text)["door"]["verified"]
    [ a1, a2 ].each(&:close)
    wait_for { @log.scan(/closed after/).size >= 2 }
    c, = page(word("wasm-alice", pass: 2))
    assert_equal "wasm-alice", @tls.names.pop(timeout: 3), "free again once the first page has gone"
    _, text = read_frame(c)
    assert JSON.parse(text)["door"]["verified"]
  end

  test "an older page (no notice asked) gets no Text on either way" do
    s, = page(word("wasm-alice", notice: false))
    assert_equal "wasm-alice", @tls.names.pop(timeout: 3)
    op, = read_frame(s)
    assert_equal 0x2, op, "InitAck first"
    t, = page(word("wasm-bob", notice: false))
    assert @ws.heads.pop(timeout: 3)
    send_binary(t, "y")
    assert_equal "\x82\x81".b, t.read(2)
  end
end
