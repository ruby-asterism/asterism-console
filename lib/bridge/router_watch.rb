# The router watch (0.3.2): a stopgap for zenohd 1.10.1, which can stop
# taking new sessions (a re-entered read lock of its routing tables while
# it answers an admin-space query, behind a waiting writer) and never comes
# back by itself. Every EVERY seconds the watch opens a brand-new Zenoh
# session to the router (the bridge's locator and certificate) and closes
# it; reusing a session would not notice, since a stuck router keeps the
# sessions it has. When FAILS checks in a row fail, it asks for the cloud
# router's restart the way Apply does (Relay::Settings.restart_command:
# bin/relay_restart_request, which writes restart.request for
# deploy/vps/zenohd/run.sh), so the bridge needs no docker rights.
#
#   - The checks are not counted for GRACE seconds after any restart request
#     (Apply's or the watch's own: restart.request's time, the newest
#     RelayApply) nor while an apply runs: zenohd is starting then.
#   - After its own restart the watch waits longer each time, while no check
#     has passed since: GRACE, then twice, four times ... up to MAX_HOLD. So
#     a router that does not come up (a wrong configuration) is not asked
#     again and again.
#   - It runs only where the console makes the cloud router's configuration
#     (Relay::Settings.config_path exists), i.e. deploy/vps; elsewhere the
#     router is not the console's to restart.
#   - The probe sessions are named by the watch (zenoh's "id", random), so
#     the bridge leaves them out of the graph before they even open
#     (Runner#read_admin: hidden_zids).
#   - What it saw goes into STATUS_FILE next to restart.request (the relay
#     pages show the last automatic restart and its reason).
#
# Settings (seconds; 0 for ASTERISM_RELAY_WATCH_EVERY turns the watch off):
#
#   ASTERISM_RELAY_WATCH_EVERY    30  between checks
#   ASTERISM_RELAY_WATCH_TIMEOUT  10  a check that has not opened by then fails
#   ASTERISM_RELAY_WATCH_FAILS    2   failed checks in a row that restart the router
#   ASTERISM_RELAY_WATCH_GRACE    60  after a restart request (and an apply), no counting
#
# With the defaults a stuck router is restarted some 50 to 80 seconds after
# it stops: the first failed check ends TIMEOUT to EVERY + TIMEOUT after
# it, the next starts EVERY after that and fails TIMEOUT later.
require "json"
require "securerandom"
require "fileutils"
require "open3"
require "timeout"

module Bridge
  class RouterWatch
    DEFAULTS = { every: 30.0, timeout: 10.0, fails: 2, grace: 60.0 }.freeze
    MAX_HOLD = 1800.0
    STATUS_FILE = "router_watch.json".freeze
    RESTART_TIMEOUT = 60
    # Probe sessions' IDs kept to hide from the graph (a stuck probe's
    # session may linger in the router's admin space for a while).
    HIDE_LAST = 8

    attr_reader :every, :timeout, :fails, :grace, :failures, :restarts, :last_error, :restarted_at, :reason,
                :hold_until

    def self.settings(env = ENV)
      num = lambda do |key, default, int: false|
        text = env[key].to_s.strip
        return default if text.empty?
        v = int ? Integer(text) : Float(text)
        raise ArgumentError, "#{key} must not be negative" if v.negative?
        v
      end
      { every: num.("ASTERISM_RELAY_WATCH_EVERY", DEFAULTS[:every]),
        timeout: num.("ASTERISM_RELAY_WATCH_TIMEOUT", DEFAULTS[:timeout]),
        fails: [ num.("ASTERISM_RELAY_WATCH_FAILS", DEFAULTS[:fails], int: true), 1 ].max,
        grace: num.("ASTERISM_RELAY_WATCH_GRACE", DEFAULTS[:grace]) }
    end

    # The status the watch last wrote (for the relay pages), or nil.
    def self.status(dir = Relay::Settings.generated_dir)
      JSON.parse(File.read(File.join(dir, STATUS_FILE)))
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # A probe for the bridge's router: opens a client session named zid with
    # the bridge's configuration (a Hash, or a JSON5 file: config_file) and
    # closes it. Raises when the session does not open.
    def self.zenoh_probe(locator, config, config_file: nil)
      lambda do |timeout, zid|
        ms = [ (timeout * 1000).round, 1 ].max
        over = { "id" => zid, "connect/timeout_ms" => ms, "transport/unicast/open_timeout" => ms }
        opts = { config: config.is_a?(Hash) ? config.merge(over) : over }
        opts[:config_file] = config_file if config_file
        ::Asterism::Zenoh::Session.open(locator, **opts).close
      end
    end

    # probe:    ->(timeout, zid) { raises when the session does not open }
    # restart:  ->(reason) { [output, ok] }
    # requested: -> Time of the newest restart request (or nil)
    # busy:     -> whether an apply runs now
    # enabled:  -> whether the console runs the cloud router here
    # status_path: where the status goes (nil: nowhere)
    def initialize(every: DEFAULTS[:every], timeout: DEFAULTS[:timeout], fails: DEFAULTS[:fails],
                   grace: DEFAULTS[:grace], probe:, restart: self.class.method(:apply_restart),
                   requested: self.class.method(:last_request), busy: self.class.method(:apply_running?),
                   enabled: self.class.method(:cloud_router_here?),
                   status_path: File.join(Relay::Settings.generated_dir, STATUS_FILE),
                   log: ->(text) { Rails.logger.info(text) }, clock: -> { Time.now }, margin: 5)
      @every = every.to_f
      @timeout = timeout.to_f
      @fails = fails
      @grace = grace.to_f
      @probe = probe
      @restart = restart
      @requested = requested
      @busy = busy
      @enabled = enabled
      @status_path = status_path
      @log = log
      @clock = clock
      @margin = margin # past the timeout, how long a check's thread is waited for
      @failures = 0
      @restarts = 0 # own restarts since the last check that passed
      @hold_until = nil
      @hidden = []
      @hidden_lock = Mutex.new
      @stuck = nil
      old = status_path && self.class.status(File.dirname(status_path))
      @restarted_at = old && old["restarted_at"]
      @reason = old && old["reason"]
    end

    def on? = @every.positive?

    # The probe sessions' IDs (normalized like Graph.norm_zid), to hide.
    def hidden_zids
      @hidden_lock.synchronize { @hidden.dup }
    end

    # Runs the watch on a thread of its own until stop is called.
    def start!
      return nil unless on?
      @stop = false
      @log.call("router watch: a new session every #{fmt(@every)} s, #{fmt(@timeout)} s to open, " \
                "restart after #{@fails} failures in a row (grace #{fmt(@grace)} s)")
      @thread = Thread.new do
        next_at = mono
        until @stop
          if mono >= next_at
            begin
              tick
            rescue StandardError => e
              @log.call("router watch: #{e.class}: #{e.message}")
            end
            next_at = mono + @every
          end
          sleep 0.2
        end
      end
    end

    def stop
      @stop = true
      @thread&.join(1)
    end

    # One check: :off, :quiet (not counted now), :ok, :failed or :restarted.
    def tick
      return :off unless on? && @enabled.call
      now = @clock.call
      if (why = quiet(now))
        @failures = 0
        write_status(now, "quiet", why)
        return :quiet
      end
      err = check
      now = @clock.call # a failed check took up to TIMEOUT
      if err.nil?
        @log.call("router watch: the router takes sessions again") if @failures.positive? || @restarts.positive?
        @failures = 0
        @restarts = 0
        @hold_until = nil
        write_status(now, "ok", nil)
        return :ok
      end
      @failures += 1
      @last_error = err
      @log.call("router watch: check failed (#{@failures}/#{@fails}): #{err}")
      if @failures < @fails
        write_status(now, "failing", nil)
        return :failed
      end
      restart!(now)
      :restarted
    end

    # Why the checks are not counted now (or nil).
    def quiet(now)
      return "an apply is running" if @busy.call
      if @hold_until && now < @hold_until
        return "waiting for the router after the automatic restart (until #{@hold_until.utc.iso8601})"
      end
      req = @requested.call
      return "a restart was requested at #{req.utc.iso8601}" if req && now < req + @grace
      nil
    end

    # Opens one probe session: nil when it opened, else what went wrong.
    def check
      if @stuck&.alive?
        return "the previous check has not returned yet"
      end
      zid = SecureRandom.hex(16)
      zid[0] = "1" if zid.start_with?("0") # zenoh prints IDs without leading zeros
      @hidden_lock.synchronize do
        @hidden << zid
        @hidden.shift while @hidden.size > HIDE_LAST
      end
      out = Queue.new
      t = Thread.new do
        @probe.call(@timeout, zid)
        out << nil
      rescue Exception => e # rubocop:disable Lint/RescueException -- the probe's thread reports everything
        out << self.class.error_text(e)
      end
      res = out.pop(timeout: @timeout + @margin)
      return res unless res.nil? && t.alive?
      @stuck = t
      "no answer within #{fmt(@timeout + @margin)} s"
    end

    def restart!(now)
      @reason = "#{@failures} checks in a row could not open a new session (last: #{@last_error})"
      @restarts += 1
      hold = [ @grace * (2**(@restarts - 1)), MAX_HOLD ].min
      hold = [ hold, @grace ].max
      @hold_until = now + hold
      @failures = 0
      @log.call("router watch: restarting the cloud router: #{@reason}")
      out, ok = @restart.call(@reason)
      @log.call("router watch: #{ok ? 'restart requested' : 'the restart request failed'}: #{out.to_s.strip}")
      @log.call("router watch: #{@restarts} restarts without a passing check in between; next count after " \
                "#{fmt(hold)} s") if @restarts > 1
      @restarted_at = now.utc.iso8601
      @reason = "#{@reason}; the request failed: #{out.to_s.strip}" unless ok
      write_status(now, ok ? "restarted" : "restart failed", nil)
    end

    def write_status(now, state, why)
      return unless @status_path
      data = { "state" => state, "checked_at" => now.utc.iso8601, "why" => why, "failures" => @failures,
               "last_error" => @last_error, "restarted_at" => @restarted_at, "reason" => @reason,
               "restarts_in_a_row" => @restarts, "every" => @every, "timeout" => @timeout, "fails" => @fails,
               "grace" => @grace }.compact
      FileUtils.mkdir_p(File.dirname(@status_path))
      tmp = "#{@status_path}.tmp#{Process.pid}"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, @status_path)
    rescue SystemCallError => e
      @log.call("router watch: cannot write #{@status_path}: #{e.message}")
    end

    # An error for the log and the page: without zenoh's source location
    # ("... Timeout! at /home/.../orchestrator.rs:383."), at most 300 characters.
    def self.error_text(e)
      "#{e.class}: #{e.message.sub(/ at \S+\.rs:\d+\.?\z/, '')}"[0, 300]
    end

    # ------------------------------------------------- the console's defaults

    # The restart Apply uses (Relay::Settings.restart_command).
    def self.apply_restart(_reason)
      cmd = Relay::Settings.restart_command
      out, status = Timeout.timeout(RESTART_TIMEOUT) { Open3.capture2e(*cmd, chdir: Relay::Settings.compose_dir) }
      [ out, status.success? ]
    rescue Timeout::Error
      [ "no end within #{RESTART_TIMEOUT} s", false ]
    rescue SystemCallError => e
      [ "#{e.class}: #{e.message}", false ]
    end

    # The newest restart request: restart.request's time (Apply's and the
    # watch's, on deploy/vps) or the newest apply's start or end (a restart
    # command of one's own, ASTERISM_RELAY_RESTART).
    def self.last_request
      times = []
      path = File.join(Relay::Settings.generated_dir, "restart.request")
      times << File.mtime(path) if File.exist?(path)
      Rails.application.executor.wrap do
        a = RelayApply.where.not(started_at: nil).order(started_at: :desc).first
        times << a.started_at << a.finished_at if a
      end
      times.compact.max
    rescue SystemCallError, ActiveRecord::ActiveRecordError
      times&.compact&.max
    end

    def self.apply_running?
      Rails.application.executor.wrap { RelayApply.running_now? }
    rescue ActiveRecord::ActiveRecordError
      false
    end

    def self.cloud_router_here?
      File.exist?(Relay::Settings.config_path)
    end

    private

    def fmt(sec) = (sec % 1).zero? ? sec.to_i.to_s : sec.to_s

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
