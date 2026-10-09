# The bridge: the one process that talks to the Zenoh network (bin/bridge).
#
#   - reads the router's admin space (@/<zid>/router, its linkstate and
#     token table) every ADMIN_EVERY seconds;
#   - follows the liveliness tokens of Asterism (asterism/**) and ROS 2
#     (@ros2_lv/**) as they come and go;
#   - builds the graph (Bridge::Graph), keeps it in GraphState and
#     broadcasts what changed (ConsoleChannel);
#   - runs the page's requests (BridgeRequest: meta, call) and subscribes
#     to the watched keys (Watch);
#   - measures ROS 2 topic rates (Bridge::Rates) while a page asks for them
#     (RateLease): one wildcard per ROS 2 domain for "all topics", or the
#     one topic whose details are open. Broadcast once a second, what
#     changed only; paused when the topics together bring in more than
#     RATES_MAX_BPS;
#   - while a plot page is open (StreamLease "plot"), subscribes to the
#     plotted topics and keys and sends their fields, decimated
#     (Bridge::Plots); while a log page is open (StreamLease "log"),
#     subscribes to /rosout and the Asterism log keys (Bridge::Logs);
#   - records (Recording rows, V4): subscribes to the recording's topics
#     and keys and writes them, with the network structure, into an MCAP
#     file (Bridge::Recorder) until it is stopped or reaches a limit;
#   - plays recordings back onto the network (Playback rows, admins only;
#     Bridge::Player).
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
    RATES_EVERY = 1.0
    # Measuring every topic stops (for RATES_PAUSE seconds, the single
    # topics go on) when the topics bring in more than this many bytes per
    # second: the bridge receives every message of every topic it measures.
    RATES_MAX_BPS = Integer(ENV.fetch("ASTERISM_RATES_MAX_BPS", 8_000_000))
    RATES_PAUSE = 60.0
    # The liveliness watches' queues. A watch reports the tokens alive now
    # in one burst when it is declared (an rclcpp node alone has some 25),
    # and asterism-zenoh's default queue of 16 drops the oldest of a burst.
    # 1024 is the binding's maximum; when a watch still drops, it is
    # declared again (Runner#check_follows).
    LIVELINESS_DEPTH = 1024
    GET_TIMEOUT = 1.5
    # The queue of a recording's subscriptions: the binding's maximum, so a
    # receiving thread held up for a moment (20 s of a 50 Hz topic) delays
    # messages instead of losing them. What is lost anyway is counted.
    RECORD_DEPTH = 1024
    # Points and log lines go out this often (one broadcast each).
    STREAMS_EVERY = 0.2

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
      @objects = objects # what runs meta and calls (Bridge::Objects; the tests pass a stand-in)
      @lock = Mutex.new
      @asterism_keys = {}
      @ros_keys = {}
      @admin = {}
      @own_links = {}
      @registry = []
      @dirty = true
      @subs = {} # watch id => [key, Subscription]
      @rate = {} # watch id => [second, count, dropped]
      @workers = []
      @outbox = Queue.new # values seen on watched keys, broadcast by the main thread
      @rates = Rates.new
      @rate_subs = {} # key expression => Subscription
      @rates_paused_until = 0.0
      @rates_status = nil
      @follows = {} # pattern => [set, Watch, dropped so far]
      @plots = Plots.new
      @plot_subs = {} # target => [key expression, Subscription]
      @plot_meta = {} # target => what the plot page is told about it
      @logs = Logs.new
      @log_subs = {} # key expression => Subscription
      @logs_dropped = 0
      @topic_types = {} # ROS 2 topic id => type (from the graph)
      @recorders = {} # recording id => { recorder:, subs: [Subscription] }
      @players = {} # playback id => Player
      @stop = false
    end

    RETRY_AFTER = 3.0

    # Serves until INT / TERM. When the router goes away (or is not there
    # yet) it tries again every RETRY_AFTER seconds.
    def run
      require "asterism"
      Types.setup
      @objects ||= Objects.new
      trap_signals
      until @stop
        begin
          serve
        rescue Asterism::Error => e # Zenoh::Error and ClosedError are under it
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
      @rate_subs = {}
      @rates.clear
      @rates_status = nil
      @follows = {}
      @plots.clear
      @plot_subs = {}
      @plot_meta = {}
      @logs.clear
      @log_subs = {}
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
      w = @z.liveliness_watch(pattern, depth: LIVELINESS_DEPTH) do |key, alive|
        @lock.synchronize do
          alive ? set[key] = true : set.delete(key)
          @dirty = true
        end
      end
      @follows[pattern] = [ set, w, 0 ]
    end

    # A watch that dropped changes (its queue was full) no longer knows
    # which tokens are alive: forget them and declare it again, which
    # reports the tokens alive now.
    def check_follows
      @follows.each do |pattern, (set, w, seen)|
        dropped = w.watch.dropped
        next if dropped == seen
        say "bridge: liveliness #{pattern}: #{dropped - seen} changes dropped, following it again"
        w.close
        @lock.synchronize do
          set.clear
          @dirty = true
        end
        follow(pattern, set)
      end
    end

    def loop_until_stopped
      next_admin = next_sync = next_beat = next_rates = next_streams = 0.0
      until @stop
        now = mono
        if now >= next_admin
          read_admin
          next_admin = now + ADMIN_EVERY
        end
        publish_graph if @lock.synchronize { @dirty }
        if now >= next_sync
          check_follows
          sync_watches
          sync_rates
          sync_plots
          sync_logs
          sync_recordings
          sync_playbacks
          expire_requests
          next_sync = now + SYNC_EVERY
        end
        if now >= next_rates
          publish_rates
          report_recordings
          next_rates = now + RATES_EVERY
        end
        @recorders.each_value { _1[:recorder].tick }
        if now >= next_streams
          publish_plots
          publish_logs
          next_streams = now + STREAMS_EVERY
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
      reg = registry
      @lock.synchronize do
        if admin != @admin || own != @own_links || reg != @registry
          @admin = admin
          @own_links = own
          @registry = reg
          @dirty = true
        end
      end
    rescue Asterism::Zenoh::ClosedError
      raise # the main loop notices and connects again
    rescue Asterism::Zenoh::Error => e
      say "bridge: admin space: #{e.message}"
    end

    # The relay registry (W2), to mark the graph's nodes by it.
    def registry
      RelayPeer.registry
    rescue ActiveRecord::ActiveRecordError
      []
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
    rescue Asterism::Zenoh::ClosedError
      raise # the main loop notices and connects again
    rescue OpenSSL::X509::CertificateError, SystemCallError
      @self_cert = nil
    end

    # The replies to a get on the admin space, as [key, text]. Through the
    # session's Get rather than Connection#get, to see the replies that
    # asterism-zenoh dropped: a get's queue holds 16 and cannot be made
    # longer, and a router answers a wildcard in one burst. Logged, once
    # per key, so a graph that misses parts of a busy network says why.
    def get_raw(key)
      g = @z.session.get(key, timeout: GET_TIMEOUT)
      out = []
      loop do
        done = g.done?
        got = g.each_result
        got.each { |r| out << [ r.key, r.payload.to_s.dup.force_encoding(Encoding::UTF_8) ] unless r.error? }
        break if done && g.pending.zero?
        sleep 0.002 if got.empty?
      end
      warn_dropped(key, g.dropped)
      out
    end

    def warn_dropped(key, dropped)
      @get_dropped ||= {}
      return @get_dropped.delete(key) if dropped.zero?
      return if @get_dropped[key]
      @get_dropped[key] = true
      say "bridge: #{key}: #{dropped} replies dropped (asterism-zenoh keeps 16 per get); the graph misses them"
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
                    self_cert: self_cert, registry: @registry).to_h
      end
      @topic_types = graph["nodes"].each_with_object({}) do |n, h|
        h[n["id"]] = n["data"]["type"] if n["kind"] == "r_topic"
      end
      state = GraphState.current
      diff = Graph.diff(state.graph, graph)
      return if Graph.empty_diff?(diff) && state.version.positive?
      state.update!(version: state.version + 1, snapshot: JSON.generate(graph), bridge_seen_at: Time.current,
                    bridge_info: JSON.generate(bridge_info))
      ConsoleChannel.send_message("graph_diff", "version" => state.version, "diff" => diff)
      @recorders.each_value { _1[:recorder].graph(state.version, graph, diff) }
      say "bridge: graph v#{state.version}: #{graph['nodes'].size} nodes, #{graph['edges'].size} edges " \
          "(+#{diff['add_nodes'].size} -#{diff['remove_nodes'].size} ~#{diff['change_nodes'].size})"
    end

    def bridge_info
      { "router" => @locator, "node" => @node_id, "zid" => @z.zid, "routers" => @z.router_zids,
        "connections" => @z.connection_count, "tls" => @locator.start_with?("tls/"), "pid" => Process.pid }
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
      timeout = req.timeout_s.to_f
      attrs =
        begin
          value =
            case req.kind
            when "meta" then @objects.meta(req.path, timeout: timeout)
            when "call"
              kw = req.kwargs_value.transform_keys(&:to_sym)
              @objects.call(req.path, req.method_name, req.args_value, kw, timeout: timeout)
            end
          { status: "ok", result: JSON.generate([ value ]) }
        rescue Asterism::RemoteError => e
          { status: "remote_error", error_class: e.remote_class, error_message: e.remote_message }
        rescue Asterism::TimeoutError => e
          { status: "timeout", error_class: e.class.name, error_message: e.message }
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
      @outbox << Payload.describe(sample.payload, key: sample.key).merge(
        "watch_id" => id, "key" => sample.key, "at" => Time.now.strftime("%H:%M:%S.%L"), "dropped" => r[2]
      )
    end

    # ------------------------------------------------------------------ rates

    # Subscribe to what the live leases ask for, drop the rest.
    def sync_rates
      wanted = RateLease.wanted
      exprs = {}
      if wanted.include?("*") && mono >= @rates_paused_until
        ros_domains.each { exprs["#{_1}/**"] = true }
      end
      wanted.each do |k|
        next if k == "*"
        e = RateLease.key_expr(k)
        exprs[e] = true unless exprs.key?("#{e.split('/').first}/**")
      end
      return if exprs.keys.sort == @rate_subs.keys.sort
      (@rate_subs.keys - exprs.keys).each do |e|
        @rate_subs.delete(e).close
        say "bridge: rates: stop #{e}"
      end
      exprs.each_key do |e|
        next if @rate_subs.key?(e)
        @rate_subs[e] = @z.subscribe(e) { |sample| @rates.record(sample.key, sample.payload) }
        say "bridge: rates: measure #{e}"
      rescue Asterism::Zenoh::Error, ArgumentError => err
        say "bridge: rates: #{e}: #{err.message}"
      end
      @rates.keep_if { |tid| Rates.covered?(tid, @rate_subs.keys) }
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: rates: #{e.message}"
    end

    def ros_domains
      @lock.synchronize { @ros_keys.keys.filter_map { _1.split("/")[1] } }.uniq.grep(/\A\d+\z/).sort
    end

    # Once a second: what changed, and how the measuring stands.
    def publish_rates
      wildcards = @rate_subs.keys.select { _1.match?(%r{\A\d+/\*\*\z}) }
      if wildcards.any? && (bps = @rates.total_bps) > RATES_MAX_BPS
        wildcards.each { @rate_subs.delete(_1).close }
        @rates_paused_until = mono + RATES_PAUSE
        @rates.keep_if { |tid| Rates.covered?(tid, @rate_subs.keys) }
        say "bridge: rates: #{bps} B/s is over #{RATES_MAX_BPS}; all topics paused for #{RATES_PAUSE.to_i} s"
      end
      paused = [ @rates_paused_until - mono, 0 ].max.round
      status = { "measuring" => @rate_subs.keys.sort, "paused_s" => paused, "limit_bps" => RATES_MAX_BPS,
                 "topics" => @rates.size, "dropped" => @rates.dropped }
      snap = @rates.snapshot
      # Nothing measured yet counts as already told; the pause's countdown
      # alone is no news.
      last = @rates_status || status.merge("measuring" => [], "topics" => 0, "dropped" => 0, "paused_s" => 0)
      same = ->(a, b) { a.merge("paused_s" => a["paused_s"].positive?) == b.merge("paused_s" => b["paused_s"].positive?) }
      return if snap.empty? && same.(status, last)
      @rates_status = status
      ConsoleChannel.send_message("rates", "rates" => snap, "status" => status)
    end

    # ------------------------------------------------------------------ plots

    # Subscribe to the targets the open plot pages lease, with the fields
    # they want; drop the rest. A target whose type is not known (not on
    # the network yet, or not bundled) is not subscribed; the pages are
    # told why, and it is tried again on the next sync.
    def sync_plots
      wanted = StreamLease.wanted("plot").first(Plots::MAX_TARGETS).to_h
      (@plot_subs.keys - wanted.keys).each do |target|
        expr, sub = @plot_subs.delete(target)
        sub.close
        @plots.remove(target)
        say "bridge: plots: stop #{expr}"
      end
      (@plot_meta.keys - wanted.keys).each { @plot_meta.delete(_1) }
      wanted.each do |target, fields|
        unless @plot_subs.key?(target)
          meta, decoder, expr = plot_source(target)
          if decoder && @plots.set(target, decoder: decoder, fields: fields)
            begin
              @plot_subs[target] = [ expr, @z.subscribe(expr) { |sample| @plots.record(target, sample.payload) } ]
              say "bridge: plots: subscribe #{expr} (#{target})"
            rescue Asterism::Zenoh::Error, ArgumentError => e
              @plots.remove(target)
              meta = meta.merge("error" => "cannot subscribe to #{expr}: #{e.message}")
            end
          end
          tell_plot_meta(target, meta.merge("observed" => @plot_meta.dig(target, "observed")).compact)
        end
        if @plot_subs.key?(target) && @plots.fields(target) != fields.first(Plots::MAX_FIELDS)
          @plots.wanted(target, fields)
          say "bridge: plots: #{target}: #{fields.size} fields (#{fields.first(6).join(', ')})"
        end
      end
      @plot_meta.each { |target, meta| StreamLease.write_meta("plot", target, meta) }
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: plots: #{e.message}"
    end

    # [meta for the page, decoder or nil, key expression] of a target.
    def plot_source(target)
      if target.start_with?("key:")
        expr = target.delete_prefix("key:")
        return [ { "target" => target, "kind" => "key", "key" => expr, "fields" => [] }, Plots.msgpack_decoder, expr ]
      end
      type = @topic_types[target]
      meta = { "target" => target, "kind" => "ros", "type" => type }
      return [ meta.merge("error" => "the topic is not on the network (no publisher or subscriber seen)"), nil, nil ] unless type
      t = Types.ros(type)
      fields = Types.fields(t)
      [ meta.merge("fields" => fields), ->(bytes) { t.decode(bytes).to_h }, RateLease.key_expr(target) ]
    rescue Types::Unknown => e
      [ meta.merge("error" => e.message), nil, nil ]
    end

    def tell_plot_meta(target, meta)
      return if @plot_meta[target] == meta
      @plot_meta[target] = meta
      StreamLease.write_meta("plot", target, meta)
      ConsoleChannel.send_to("plots", "plot_meta", "meta" => meta)
    end

    def publish_plots
      return if @plot_subs.empty?
      points, observed = @plots.drain
      observed.each { |target, seen| tell_plot_meta(target, (@plot_meta[target] || {}).merge("observed" => seen)) }
      ConsoleChannel.send_to("plots", "plot", "points" => points) unless points.empty?
    end

    # ------------------------------------------------------------------- logs

    # While a log page is open: /rosout of every ROS 2 domain seen, and the
    # Asterism log keys.
    def sync_logs
      exprs = []
      if StreamLease.wanted("log").any?
        exprs = ros_domains.map { "#{_1}/rosout/**" } << Logs::ASTERISM_KEY
      end
      return if exprs.sort == @log_subs.keys.sort
      (@log_subs.keys - exprs).each do |e|
        @log_subs.delete(e).close
        say "bridge: logs: stop #{e}"
      end
      exprs.each do |e|
        next if @log_subs.key?(e)
        @log_subs[e] = @z.subscribe(e) { |sample| @logs.record(sample.key, sample.payload) }
        say "bridge: logs: subscribe #{e}"
      rescue Asterism::Zenoh::Error, ArgumentError => err
        say "bridge: logs: #{e}: #{err.message}"
      end
      @logs.clear if @log_subs.empty?
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: logs: #{e.message}"
    end

    def publish_logs
      return if @log_subs.empty?
      lines = @logs.drain
      return if lines.empty? && @logs.dropped == @logs_dropped
      @logs_dropped = @logs.dropped
      ConsoleChannel.send_to("logs", "logs", "lines" => lines, "dropped" => @logs.dropped, "errors" => @logs.errors)
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

    # ------------------------------------------------------------- recordings

    # Starts the pending recordings, ends the stopped ones and those at a
    # limit. A row that says "recording" with no recorder here is left from
    # a bridge that stopped without finishing it: its file is given a
    # summary (Bag::Repair) and the row ends.
    def sync_recordings
      rows = Recording.where(status: Recording::ACTIVE).to_a
      rows.each do |r|
        entry = @recorders[r.id]
        case r.status
        when "pending" then start_recording(r) unless entry
        when "recording"
          if entry.nil? then recover_recording(r)
          elsif (why = entry[:recorder].limit_reached) then finish_recording(r, why)
          end
        when "stopping"
          entry ? finish_recording(r, "stopped") : recover_recording(r)
        end
      end
      (@recorders.keys - rows.map(&:id)).each do |id| # the row went (deleted): just close
        entry = @recorders.delete(id)
        entry[:subs].each { _1.close rescue nil }
        entry[:recorder].finish("the recording was deleted")
        say "bridge: recording #{id}: deleted while recording"
      end
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: recordings: #{e.message}"
    end

    def start_recording(r)
      sel = r.selection_value
      rec = Recorder.new(id: r.id, path: r.path, max_bytes: r.max_bytes, max_seconds: r.max_seconds,
                         structure: sel["structure"]) { |tid| ros_qos(tid) }
      rec.open
      subs = []
      sel["topics"].each do |tid|
        expr = RateLease.key_expr(tid)
        subs << @z.subscribe(expr, depth: RECORD_DEPTH) { |sample| rec.ros(sample) }
      end
      sel["keys"].each do |expr|
        subs << @z.subscribe(expr, depth: RECORD_DEPTH) { |sample| rec.key(expr, sample) }
      end
      rec.lost = -> { subs.sum { _1.respond_to?(:dropped) ? _1.dropped.to_i : 0 } }
      @recorders[r.id] = { recorder: rec, subs: subs }
      if sel["structure"]
        state = GraphState.current
        rec.graph(state.version, state.graph)
      end
      r.update!(status: "recording", started_at: Time.current)
      say "bridge: recording #{r.id} (#{r.filename}): #{sel['topics'].size} topics, #{sel['keys'].size} keys" \
          "#{sel['structure'] ? ', the network structure' : ''}"
    rescue Asterism::Zenoh::ClosedError
      raise
    rescue StandardError => e
      subs&.each { _1.close rescue nil }
      rec&.finish
      @recorders.delete(r.id)
      r.update!(status: "failed", error: "#{e.class}: #{e.message}", finished_at: Time.current)
      say "bridge: recording #{r.id}: #{e.class}: #{e.message}"
    end

    def finish_recording(r, why)
      entry = @recorders.delete(r.id)
      entry[:subs].each { _1.close rescue nil }
      p = entry[:recorder].finish(why)
      reason = entry[:recorder].stop_reason || why
      info = read_info(r)
      r.update!(status: "done", stop_reason: reason, finished_at: Time.current, **progress_attrs(p),
                info: info && JSON.generate(info))
      say "bridge: recording #{r.id}: #{reason}; #{p['messages']} messages, #{p['bytes']} bytes"
    end

    # A recording left by a bridge that did not finish it.
    def recover_recording(r)
      if r.file?
        n = Bag::Repair.call(r.path)
        info = read_info(r)
        r.update!(status: "done", stop_reason: "the bridge stopped during the recording; what it had written is kept",
                  finished_at: Time.current, messages: n, bytes: File.size(r.path), info: info && JSON.generate(info))
      else
        r.update!(status: "failed", error: "the bridge stopped before writing anything", finished_at: Time.current)
      end
      say "bridge: recording #{r.id}: recovered (#{r.status})"
    rescue MCAP::Error, SystemCallError => e
      r.update!(status: "failed", error: "the bridge stopped during the recording; the file does not read: #{e.message}",
                finished_at: Time.current)
    end

    def read_info(r)
      reader = MCAP::Reader.new(r.path.to_s)
      reader.info
    rescue MCAP::Error, SystemCallError
      nil
    ensure
      reader&.close
    end

    def progress_attrs(p)
      { messages: p["messages"], bytes: p["bytes"], duration_s: p["duration_s"], lost: p["lost"].to_i + p["dropped"].to_i,
        channel_counts: JSON.generate(p["channel_counts"]) }
    end

    # Once a second: the progress of the running recordings into their rows.
    def report_recordings
      @recorders.each do |id, entry|
        Recording.where(id: id, status: "recording").update_all(progress_attrs(entry[:recorder].progress).merge(updated_at: Time.current))
      end
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: recordings: #{e.message}"
    end

    def stop_recordings(why)
      @recorders.keys.each do |id|
        r = Recording.find_by(id: id)
        if r
          finish_recording(r, why)
        else
          entry = @recorders.delete(id)
          entry[:subs].each { _1.close rescue nil }
          entry[:recorder].finish(why)
        end
      rescue StandardError => e
        say "bridge: recording #{id}: #{e.class}: #{e.message}"
      end
    end

    # The QoS profiles of a topic's publishers, from their liveliness tokens.
    def ros_qos(tid)
      domain, name = tid.delete_prefix("r_topic:").split("/", 2)
      keys = @lock.synchronize { @ros_keys.keys }
      keys.filter_map do |k|
        t = Graph.parse_ros_token(k)
        Bag::Qos.parse(t[:qos]) if t && t[:kind] == :publisher && t[:domain] == domain && t[:name] == "/#{name}"
      end
    end

    # -------------------------------------------------------------- playbacks

    # Starts a pending playback (one at a time), follows the running one,
    # stops it when asked. The rows are the audit log.
    def sync_playbacks
      Playback.where(status: Playback::ACTIVE).order(:id).each do |pb|
        pl = @players[pb.id]
        case pb.status
        when "pending"
          if pb.created_at < Playback::EXPIRE_AFTER.ago
            pb.update!(status: "failed", error: "the bridge did not pick it up in time", finished_at: Time.current)
          elsif @players.empty?
            start_player(pb)
          end
        when "running"
          if pl.nil?
            pb.update!(status: "failed", error: "the bridge restarted during the playback", finished_at: Time.current)
          elsif !pl.alive?
            end_player(pb, pl, pl.error ? "failed" : "done")
          else
            pb.update!(messages_sent: pl.sent, skipped: JSON.generate(pl.skipped))
          end
        when "stopping"
          pl&.stop
          if pl.nil? || !pl.alive?
            end_player(pb, pl, "stopped")
          end
        end
      end
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: playbacks: #{e.message}"
    end

    def start_player(pb)
      rec = pb.recording
      unless rec&.file?
        pb.update!(status: "failed", error: "the recording's file is gone", finished_at: Time.current)
        return
      end
      pl = Player.new(playback_id: pb.id, path: rec.path, speed: pb.speed, channel_ids: pb.channel_ids,
                      start_ns: pb.start_ns, session: @z.session, put: ->(key, bytes) { @z.put(key, bytes) },
                      logger: ->(text) { say(text) })
      @players[pb.id] = pl.start
      pb.update!(status: "running", started_at: Time.current)
      say "bridge: playback #{pb.id}: #{rec.filename} at #{pb.speed}x (by #{pb.user&.email_address || '?'})"
    end

    def end_player(pb, pl, status)
      pl&.join(2)
      @players.delete(pb.id)
      pb.update!(status: status, messages_sent: pl&.sent.to_i, skipped: JSON.generate(pl&.skipped || {}),
                 error: pl&.error, finished_at: Time.current)
      say "bridge: playback #{pb.id}: #{status}, #{pl&.sent.to_i} messages sent"
    end

    def stop_players
      @players.each_value(&:stop)
      @players.each_value { _1.join(2) }
      @players.each do |id, pl|
        Playback.where(id: id, status: Playback::ACTIVE).update_all(
          status: "stopped", messages_sent: pl.sent, error: "the bridge stopped", finished_at: Time.current
        )
      end
      @players.clear
    rescue ActiveRecord::ActiveRecordError => e
      say "bridge: playbacks: #{e.message}"
    end

    # --------------------------------------------------------------- shutdown

    def shutdown
      stop_recordings("the bridge stopped (or lost its router)")
      stop_players
      @workers.each { _1.join(3) }
      @workers.clear
      @subs.each_value { _1[1].close rescue nil }
      @subs.clear
      @rate_subs.each_value { _1.close rescue nil }
      @rate_subs.clear
      @rates.clear
      @plot_subs.each_value { _1[1].close rescue nil }
      @plot_subs.clear
      @plots.clear
      @log_subs.each_value { _1.close rescue nil }
      @log_subs.clear
      @logs.clear
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
