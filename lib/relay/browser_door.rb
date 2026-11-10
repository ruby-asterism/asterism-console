# The browsers the router tells apart (T8, docs/g1_5.md "Browsers the
# router tells apart"), in the pass door (bin/ws_door). A browser page comes
# through the web server, which has asked the console about its pass; the
# console's answer says whose page it is (X-Asterism-Browser, signed with
# the console's key in the browsers' store, Relay::BrowserCerts.door_word,
# so a header the browser sent itself is worth nothing):
#
#   node=wasm-alice; pass=12; opened=<Unix ms>; notice=1; until=<Unix s>; mac=<HMAC-SHA256>
#
# The page goes to zenohd's mutual-TLS port with the user's certificate
# (browsers/wasm-alice.pem) when
#
# - the word is the console's and names a node (the user's own browser node;
#   an older link's wasm-alice_2 or a pass for a handle given up names none),
# - the router's configuration lets the node in (browsers/browsers.json,
#   written on apply) and its files are here, and
# - no page opened later (another pass, by the time the console saw it first:
#   "opened") has the node (T8c). A page opened later takes the node over: the
#   door closes the earlier page's connections with the certificate, and when
#   that page connects again (zenoh-pico does by itself) it goes through the
#   shared ws/ and is told so (taken_over in its notice). A page's own
#   sessions and reconnections come with its pass and take the node again.
#   The door remembers the latest page per node (not its connections only),
#   so an earlier page that connects again while the later one is away does
#   not take the name back.
#
# Otherwise it goes on to zenohd's ws/ as before (bin/ws_door's relay), the
# shared subject of every browser without a certificate.
#
# With a certificate the door ends the WebSocket itself and moves the
# batches between the framings, as the rooms' door does (Relay::WsFrames).
# A page that asked for it (notice=1: the browser build from T8 on) gets
# one Text message before anything of Zenoh, either way:
#
#   {"door": {"verified": true, "node": "wasm-alice"}}
#   {"door": {"verified": false, "why": "..."}}
#   {"door": {"verified": false, "why": "...", "taken_over": true}}  (T8c)
#
# An older page is sent no Text (it would take it for a batch).
require "socket"
require "openssl"
require "json"
require "digest"
require "base64"
require_relative "ws_frames"

module Relay
  class BrowserDoor
    include WsFrames

    WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze
    WORD = /\Anode=([A-Za-z0-9._-]{0,63}); pass=(\d{1,18}); opened=(\d{1,15}); notice=([01]); until=(\d{1,12}); mac=(\h{64})\z/
    # The start of the reason an earlier page is given (its notice says
    # taken_over, the page says so on its Network line).
    TAKEN = "a page opened later from the console took over".freeze
    # The close code the earlier page's WebSockets get (4000-4999: the
    # application's; the page connects again as after any close).
    TAKEN_CODE = 4409
    CHECK_SECONDS = 2.0

    # One page's connection with a certificate.
    Conn = Struct.new(:client, :tls, :node, :pass, :wlock, :closing, keyword_init: true) do
      def close
        return if closing
        self.closing = true
        [ tls, client ].each do |s|
          s&.close
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        end
      end
    end

    # upstream: zenohd's mutual-TLS listener; tls_name: the name its
    # certificate carries; dir: the browsers' store (the rooms' volume,
    # browsers/).
    def initialize(upstream:, dir:, tls_name: nil, max_message: 65_535, log: ->(m) { $stdout.puts(m) })
      @upstream = upstream
      @tls_name = tls_name || split_hostport(upstream)[0]
      @dir = dir
      @max_message = max_message
      @log = log
      @lock = Mutex.new
      @holders = {} # node => { pass:, opened:, conns: [] }: the latest page per node
      @contexts = {}
      @nodes = [ nil, [] ]
      @key = [ nil, nil ]
    end

    attr_reader :upstream

    # The console's word in the request head: {node, pass, notice, until}
    # when its signature checks, else nil.
    def word(head)
      text = head[/^X-Asterism-Browser:\s*([^\r\n]*?)\s*$/i, 1] or return nil
      m = WORD.match(text) or return nil
      key = door_key or return nil
      signed = text.sub(/; mac=\h{64}\z/, "")
      return nil unless OpenSSL.fixed_length_secure_compare(OpenSSL::HMAC.hexdigest("SHA256", key, signed), m[6])
      { node: m[1], pass: m[2], opened: m[3].to_i, notice: m[4] == "1", until: m[5].to_i }
    end

    # Why this page goes to the shared ws/ (a String), or nil: it may take
    # its node with the certificate. The node stays its pass's until a page
    # opened later claims it; that page takes it over and the holder's
    # connections are closed.
    def claim(w)
      return "no certificate for this page (the console names none: an older link, or no handle)" if w[:node].empty?
      return "#{w[:node]} is not in the router's configuration yet (apply)" unless applied?(w[:node])
      return "no certificate for #{w[:node]} at the door" unless files?(w[:node])
      gone = nil
      @lock.synchronize do
        h = @holders[w[:node]]
        if h && h[:pass] != w[:pass]
          return "#{TAKEN} #{w[:node]}" unless later?(w, h)
          gone = h
        end
        @holders[w[:node]] = { pass: w[:pass], opened: w[:opened], conns: [] } if h.nil? || gone
      end
      take_over(w, gone) if gone
      nil
    end

    # Whether the reason is that a later page has the node.
    def self.taken_over?(why) = why.to_s.start_with?(TAKEN)

    # The holder of node now: [pass, its open connections with the
    # certificate], for the tests.
    def holder(node)
      @lock.synchronize { (h = @holders[node]) && [ h[:pass], h[:conns].size ] }
    end

    # The connection to zenohd's tls/ with node's certificate, or nil.
    def connect(node)
      tcp = Socket.tcp(*split_hostport(@upstream), connect_timeout: 3)
      tls = OpenSSL::SSL::SSLSocket.new(tcp, context(node))
      tls.hostname = @tls_name
      tls.sync_close = true
      tls.connect
      tls
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError, OpenSSL::PKey::PKeyError, SocketError => e
      @log.call("browsers: #{node}: no TLS link to #{@upstream} (#{e.class}: #{e.message})")
      tcp&.close rescue nil
      nil
    end

    # The page with its certificate, on tls (connected by #connect): 101,
    # the notice, then the batches both ways until either side closes or
    # limit seconds have passed. Returns why it ended.
    def serve(client, head, tls, w, limit)
      key = head[/^Sec-WebSocket-Key:\s*(\S+)/i, 1] or raise IOError, "no Sec-WebSocket-Key"
      accept = Base64.strict_encode64(Digest::SHA1.digest(key + WS_GUID))
      conn = Conn.new(client: client, tls: tls, node: w[:node], pass: w[:pass], wlock: Mutex.new)
      return "#{TAKEN} #{w[:node]} before this one started" unless attach(conn)
      client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
      ws_write(client, 0x1, self.class.notice(true, node: w[:node]), conn.wlock) if w[:notice]
      [ client, tls.to_io ].each { _1.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil }
      pump(conn, limit)
    ensure
      detach(conn) if conn
    end

    def self.notice(verified, node: nil, why: nil)
      taken = verified || !taken_over?(why) ? nil : true
      JSON.generate({ "door" => { "verified" => verified, "node" => node, "why" => why, "taken_over" => taken }.compact })
    end

    # A Text frame from the door (unmasked), for the shared path too.
    def self.text_frame(text)
      data = text.b
      n = data.bytesize
      head = n < 126 ? [ 0x81, n ].pack("CC") : [ 0x81, 126, n ].pack("CCn")
      head + data
    end

    private

    # [opened, pass] orders the pages: the one the console saw first later
    # wins (the pass breaks a tie).
    def later?(w, h) = ([ w[:opened], w[:pass].to_i ] <=> [ h[:opened], h[:pass].to_i ]).positive?

    # A connection #serve made, kept with its holder so a later page can
    # close it. False when a later page took the node in between.
    def attach(conn)
      @lock.synchronize do
        h = @holders[conn.node]
        return false unless h && h[:pass] == conn.pass
        h[:conns] << conn
      end
      true
    end

    def detach(conn)
      @lock.synchronize { @holders[conn.node]&.[](:conns)&.delete(conn) }
    end

    # The earlier page's connections with the certificate end (a close
    # frame with TAKEN_CODE, then the sockets); it connects again by
    # itself and goes to the shared ws/ (#claim).
    def take_over(w, gone)
      conns = @lock.synchronize { gone[:conns].dup }
      @log.call("browsers: #{w[:node]}: pass #{w[:pass]} (opened later) takes it over from pass #{gone[:pass]}; " \
                "closing its #{conns.size} connection(s) with the certificate")
      conns.each do |c|
        ws_write(c.client, 0x8, [ TAKEN_CODE ].pack("n") + "taken over by a page opened later", c.wlock)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        c.close
      end
    end

    def split_hostport(s)
      host, _, port = s.rpartition(":")
      [ host.delete_prefix("[").delete_suffix("]"), Integer(port) ]
    end

    def cached(path, slot)
      mtime = File.mtime(path)
      return slot[1] if slot[0] == mtime
      value = yield
      slot.replace([ mtime, value ])
      value
    rescue SystemCallError
      slot.replace([ nil, nil ])
      nil
    end

    def door_key
      key = cached(File.join(@dir, "door.key"), @key) { File.read(File.join(@dir, "door.key")).strip }
      key.to_s.match?(/\A\h{64}\z/) ? key : nil
    end

    def applied?(node)
      list = cached(File.join(@dir, "browsers.json"), @nodes) do
        Array(JSON.parse(File.read(File.join(@dir, "browsers.json")))["nodes"]).map(&:to_s)
      rescue JSON::ParserError, TypeError, NoMethodError
        []
      end
      Array(list).include?(node)
    end

    def files?(node)
      %w[pem key].all? { File.exist?(File.join(@dir, "#{node}.#{_1}")) } && File.exist?(File.join(@dir, "ca.pem"))
    end

    def context(node)
      cert_file = File.join(@dir, "#{node}.pem")
      mtime = File.mtime(cert_file)
      cached = @lock.synchronize { @contexts[node] }
      return cached[1] if cached && cached[0] == mtime
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(cert_file))
      ctx.key = OpenSSL::PKey.read(File.read(File.join(@dir, "#{node}.key")))
      ctx.ca_file = File.join(@dir, "ca.pem")
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.verify_hostname = true
      @lock.synchronize { @contexts[node] = [ mtime, ctx ] }
      ctx
    end

    def pump(conn, limit)
      client = conn.client
      tls = conn.tls
      ended = nil
      timer = Thread.new do
        sleep limit
        ended ||= "lifetime #{limit.round} s reached"
        conn.close
      end
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
          when 0x9 then ws_write(client, 0xA, data, conn.wlock)
          when 0xA then nil
          when 0x8 then break
          else raise IOError, "WebSocket opcode #{op}"
          end
        end
        ended ||= "closed by the browser side"
      rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        ended ||= e.is_a?(EOFError) ? "closed by the browser side" : "from the browser: #{e.message}"
      ensure
        conn.close
      end
      first = true
      begin
        loop do # zenohd -> browser
          len = read_exact(tls, 2).unpack1("v")
          batch = read_exact(tls, len)
          if first
            batch, = WsFrames.rewrite_init_ack(batch)
            first = false
          end
          ws_write(client, 0x2, batch, conn.wlock)
        end
      rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
        ended ||= "closed by zenohd"
      ensure
        conn.close
      end
      up.join
      timer.kill
      ended
    end
  end
end
