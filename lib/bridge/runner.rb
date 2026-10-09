# The bridge: the one process that talks to the Zenoh network (bin/bridge).
#
#   - reads the router's admin space (@/<zid>/router, its linkstate and
#     token table) every ADMIN_EVERY seconds;
#   - follows the liveliness tokens of Asterism (asterism/**) and ROS 2
#     (@ros2_lv/**) as they come and go;
#   - builds the graph (Bridge::Graph), keeps it in GraphState and
#     broadcasts what changed (ConsoleChannel);
#   - runs the page's requests (BridgeRequest: meta, call) and subscribes
#     to the watched keys (Watch).
#
# Two sessions: a plain Zenoh one for reading, and the object layer's
# (Asterism.connect, node ASTERISM_CONSOLE_NODE / app "console") for meta
# and calls. Puma never loads Asterism.
#
# Both sessions take the same zenoh configuration (Runner.zenoh_config):
# ASTERISM_ZENOH_CONFIG, a JSON5 file, or for TLS ASTERISM_TLS_CA (the CA
# of the router's certificate) with ASTERISM_TLS_CERT / ASTERISM_TLS_KEY
# (this bridge's certificate, for a router that asks for one: mutual TLS).
require "openssl"

module Bridge
  class Runner
    ADMIN_EVERY = 2.0
    TICK = 0.1
    SYNC_EVERY = 0.5
    HEARTBEAT_EVERY = 3.0
    MAX_WORKERS = 4
    # At most this many values per watched key and second reach the page.
    WATCH_RATE = 10

    attr_reader :locator, :node_id, :config

    # The zenoh configuration from the environment (nil: zenoh's defaults).
    def self.zenoh_config(env = ENV)
      file = env["ASTERISM_ZENOH_CONFIG"].to_s
      return File.read(file) unless file.empty?
      ca = env["ASTERISM_TLS_CA"].to_s
      cert = env["ASTERISM_TLS_CERT"].to_s
      return nil if ca.empty? && cert.empty?
      cfg = {}
      cfg["transport/link/tls/root_ca_certificate"] = ca unless ca.empty?
      unless cert.empty?
        cfg["transport/link/tls/connect_certificate"] = cert
        cfg["transport/link/tls/connect_private_key"] = env.fetch("ASTERISM_TLS_KEY")
        cfg["transport/link/tls/enable_mtls"] = true
      end
      cfg
    end

    def initialize(locator: ENV.fetch("ASTERISM_ROUTER", "tcp/127.0.0.1:7447"),
                   node_id: ENV.fetch("ASTERISM_CONSOLE_NODE", "console"),
                   app: "console", logger: Rails.logger, objects: nil, config: self.class.zenoh_config)
      @locator = locator
      @config = config
      @node_id = node_id
      @app = app
      @log = logger
      @objects = objects # what runs meta and calls (Asterism; the tests pass a stand-in)
      @lock = Mutex.new
      @asterism_keys = {}
      @ros_keys = {}
      @admin = {}
      @own_links = {}
      @dirty = true
      @subs = {} # watch id => [key, Subscription]
      @rate = {} # watch id => [second, count, dropped]
      @workers = []
      @outbox = Queue.new # values seen on watched keys, broadcast by the main thread
      @stop = false
    end

    RETRY_AFTER = 3.0

    # Serves until INT / TERM. When the router goes away (or is not there
    # yet) it tries again every RETRY_AFTER seconds.
    def run
      require "asterism"
      @objects ||= Asterism
      trap_signals
      until @stop
        begin
          serve
        rescue Asterism::Error, Asterism::Zenoh::Error => e
          say "bridge: #{e.class}: #{e.message}"
        ensure
          shutdown
        end
        break if @stop
        say "bridge: trying again in #{RETRY_AFTER} s"
        t = mono + RETRY_AFTER
        sleep 0.1 while !@stop && mono < t
      end
      mark_stopped
    end

    def serve
      say "bridge: connecting to #{@locator} as #{@node_id}/#{@app}"
      reset
      opts = @config ? { config: @config } : {}
      @z = Asterism::Zenoh.open(@locator, **opts)
      Asterism.connect(@locator, node: @node_id, app: @app, **opts)
      @net = Asterism.net
      @net.on_error { |e, where| say "bridge: #{where}: #{e.class}: #{e.message}" }
      @net.start
      @z.on_error { |e, where| say "bridge: #{where}: #{e.class}: #{e.message}" }
      follow("asterism/**", @asterism_keys)
      follow("@ros2_lv/**", @ros_keys)
      @z.start
      @self_zids = [ @z.zid ]
      say "bridge: zid #{@z.zid}, routers #{@z.router_zids.join(' ')}"
      loop_until_stopped
    end

    def reset
      @lock.synchronize do
        @asterism_keys.clear
        @ros_keys.clear
        @admin = {}
        @own_links = {}
        @dirty = true
      end
      @subs = {}
      @rate = {}
    end

    def stop
      @stop = true
    end

    private

    def say(text)
      @log.info(text)
      $stdout.puts("#{Time.now.strftime('%H:%M:%S.%L')} #{text}")
      $stdout.flush
    end

    def trap_signals
      %w[INT TERM].each { |sig| Signal.trap(sig) { @stop = true } }
    end

    def follow(pattern, set)
      @z.liveliness_watch(pattern) do |key, alive|
        @lock.synchronize do
          alive ? set[key] = true : set.delete(key)
          @dirty = true
        end
      end
    end

    def loop_until_stopped
      next_admin = next_sync = next_beat = 0.0
      until @stop
        now = mono
        if now >= next_admin
          read_admin
          next_admin = now + ADMIN_EVERY
        end
        publish_graph if @lock.synchronize { @dirty }
        if now >= next_sync
          sync_watches
          expire_requests
          next_sync = now + SYNC_EVERY
        end
        take_requests
        flush_outbox
        if now >= next_beat
          heartbeat
          next_beat = now + HEARTBEAT_EVERY
        end
        unless @z.running? && Asterism.connected?
          say "bridge: connection lost (#{Asterism.lost_reason || 'zenoh session closed'})"
          break
        end
        sleep TICK
      end
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # ----------------------------------------------------------- admin space

    def read_admin
      admin = {}
      get_json("@/*/router").each do |key, v|
        rz = key.split("/")[1]
        (admin[rz] ||= { "tokens" => {}, "linkstate" => {} })["router"] = v
      end
      get_raw("@/*/router/linkstate/**").each do |key, text|
        rz = key.split("/")[1]
        (admin[rz] ||= { "tokens" => {}, "linkstate" => {} })["linkstate"][key.split("/linkstate/", 2)[1]] = text
      end
      get_json("@/*/router/token/**").each do |key, v|
        rz = key.split("/")[1]
        (admin[rz] ||= { "tokens" => {}, "linkstate" => {} })["tokens"][key.split("/token/", 2)[1]] = v
      end
      own = own_links
      @lock.synchronize do
        if admin != @admin || own != @own_links
          @admin = admin
          @own_links = own
          @dirty = true
        end
      end
    rescue Asterism::Zenoh::Error => e
      say "bridge: admin space: #{e.message}"
    end

    # This bridge's links (to the router it is connected to): the link's
    # protocol and the certificate name the router showed (TLS). zenohd
    # keeps the certificate names of its other links in the session part of
    # its admin space (@/<zid>/session/**), which answers local queries only.
    def own_links
      @z.links.to_h do |l|
        [ l.zid, { "protocol" => Graph.protocol(l.dst), "cert_name" => l.auth_identifier }.compact ]
      end
    rescue Asterism::Zenoh::Error, NoMethodError
      {}
    end

    # The common name of this bridge's certificate (mutual TLS), or nil.
    def self_cert
      return @self_cert if defined?(@self_cert)
      file = @config.is_a?(Hash) ? @config["transport/link/tls/connect_certificate"] : nil
      @self_cert = file && OpenSSL::X509::Certificate.new(File.read(file)).subject.to_a.find { _1[0] == "CN" }&.dig(1)
    rescue OpenSSL::X509::CertificateError, SystemCallError
      @self_cert = nil
    end

    def get_raw(key)
      @z.get(key, timeout: 1.5).map { |r| [ r.key, r.payload.to_s.dup.force_encoding(Encoding::UTF_8) ] }
    end

    def get_json(key)
      get_raw(key).filter_map do |k, text|
        [ k, JSON.parse(text) ]
      rescue JSON::ParserError
        nil
      end
    end

    # ------------------------------------------------------------------ graph

    def publish_graph
      graph = @lock.synchronize do
        @dirty = false
        Graph.build(admin: @admin, asterism: @asterism_keys.keys, ros: @ros_keys.keys,
                    self_node: @node_id, self_zids: @self_zids, own_links: @own_links,
                    self_cert: self_cert).to_h
      end
      state = GraphState.current
      diff = Graph.diff(state.graph, graph)
      return if Graph.empty_diff?(diff) && state.version.positive?
      state.update!(version: state.version + 1, snapshot: JSON.generate(graph), bridge_seen_at: Time.current,
                    bridge_info: JSON.generate(bridge_info))
      ConsoleChannel.send_message("graph_diff", "version" => state.version, "diff" => diff)
      say "bridge: graph v#{state.version}: #{graph['nodes'].size} nodes, #{graph['edges'].size} edges " \
          "(+#{diff['add_nodes'].size} -#{diff['remove_nodes'].size} ~#{diff['change_nodes'].size})"
    end

    def bridge_info
      { "router" => @locator, "node" => @node_id, "zid" => @z.zid, "routers" => @z.router_zids,
        "tls" => @locator.start_with?("tls/"), "pid" => Process.pid }
    end

    def heartbeat
      state = GraphState.current
      state.update!(bridge_seen_at: Time.current, bridge_info: JSON.generate(bridge_info))
      ConsoleChannel.send_message("bridge", "bridge" => state.info.merge("alive" => true), "version" => state.version)
    end

    # --------------------------------------------------------------- requests

    def take_requests
      @workers.reject! { !_1.alive? }
      return if @workers.size >= MAX_WORKERS
      BridgeRequest.pending.order(:id).limit(MAX_WORKERS - @workers.size).each do |req|
        # Claim it (another bridge, if one were started by mistake, would
        # fail to connect as the same node anyway).
        next unless BridgeRequest.where(id: req.id, status: "pending").update_all(status: "running").positive?
        @workers << Thread.new(req.reload) { |r| perform(r) }
      end
    end

    def expire_requests
      BridgeRequest.pending.where(created_at: ...BridgeRequest::EXPIRE_AFTER.ago).find_each do |r|
        r.update!(status: "expired", error_message: "the bridge did not pick it up in time", finished_at: Time.current)
        ConsoleChannel.send_message("request", "request" => r.as_payload)
      end
    end

    def perform(req)
      # The page checked the call permissions when it wrote the row; check
      # again here (a row may have been removed since, or written by hand).
      unless req.permitted?
        req.deny!("no call permission allows it (checked by the bridge)")
        say "bridge: #{req.kind} #{req.path} #{req.method_name} -> denied"
        ConsoleChannel.send_message("request", "request" => req.as_payload)
        return
      end
      t0 = mono
      timeout_ms = (req.timeout_s * 1000).round
      attrs =
        begin
          value =
            case req.kind
            when "meta" then @objects.meta(req.path, timeout_ms)
            when "call"
              kw = req.kwargs_value.transform_keys(&:to_sym)
              @objects.call(req.path, req.method_name, req.args_value, kw, timeout_ms)
            end
          { status: "ok", result: JSON.generate([ value ]) }
        rescue Asterism::RemoteError => e
          { status: "remote_error", error_class: e.remote_class, error_message: e.remote_message }
        rescue Asterism::Timeout => e
          { status: "timeout", error_class: "Asterism::Timeout", error_message: e.message }
        rescue Asterism::Error, ArgumentError, JSON::GeneratorError => e
          { status: "error", error_class: e.class.name, error_message: e.message }
        end
      # JSON round trip through an array: a bare value (a number, nil) is
      # kept as it is.
      attrs[:result] = JSON.generate(JSON.parse(attrs[:result])[0]) if attrs[:result]
      req.update!(attrs.merge(took_ms: ((mono - t0) * 1000).round(1), finished_at: Time.current))
      say "bridge: #{req.kind} #{req.path} #{req.method_name} -> #{req.status} (#{req.took_ms} ms)"
      ConsoleChannel.send_message("request", "request" => req.as_payload)
    rescue StandardError => e
      say "bridge: request #{req.id}: #{e.class}: #{e.message}"
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end

    # ---------------------------------------------------------------- watches

    def sync_watches
      wanted = Watch.all.to_h { [ _1.id, _1 ] }
      (@subs.keys - wanted.keys).each do |id|
        @subs.delete(id)[1].close
        @rate.delete(id)
        say "bridge: unwatch #{id}"
      end
      wanted.each do |id, w|
        next if @subs.key?(id) || w.error.present?
        begin
          @subs[id] = [ w.key, @z.subscribe(w.key) { |sample| watched(id, sample) } ]
          say "bridge: watch #{w.key}"
        rescue Asterism::Zenoh::Error, ArgumentError => e
          w.update!(error: e.message)
          ConsoleChannel.send_message("watch", "watch" => w.as_payload)
        end
      end
    end

    def watched(id, sample)
      sec = Time.now.to_i
      r = (@rate[id] ||= [ sec, 0, 0 ])
      if r[0] != sec
        r[0] = sec
        r[1] = 0
      end
      r[1] += 1
      if r[1] > WATCH_RATE
        r[2] += 1
        return
      end
      @outbox << Payload.describe(sample.payload).merge(
        "watch_id" => id, "key" => sample.key, "at" => Time.now.strftime("%H:%M:%S.%L"), "dropped" => r[2]
      )
    end

    # Called on the receiving thread, so the database (Action Cable's
    # adapter) is left to the main thread.
    def flush_outbox
      until @outbox.empty?
        ConsoleChannel.send_message("sample", @outbox.pop(true))
      end
    rescue ThreadError
      nil
    end

    # --------------------------------------------------------------- shutdown

    def shutdown
      @workers.each { _1.join(3) }
      @workers.clear
      @subs.each_value { _1[1].close rescue nil }
      @subs.clear
      Asterism.close
      @z&.close
      @z = nil
      say "bridge: closed"
    rescue StandardError => e
      say "bridge: shutdown: #{e.class}: #{e.message}"
    end

    # The page shows the bridge as gone at once rather than after the
    # heartbeat runs out.
    def mark_stopped
      return unless (state = GraphState.first)
      state.update!(bridge_seen_at: nil)
      ConsoleChannel.send_message("bridge", "bridge" => state.info.merge("alive" => false), "version" => state.version)
    end
  end
end
