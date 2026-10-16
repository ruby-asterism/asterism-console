require "test_helper"
require "tmpdir"

# The router watch (0.3.2): new sessions opened and closed against the
# router; FAILS failures in a row ask for its restart the way Apply does.
# No zenohd here: the probe, the restart and the clock are stand-ins.
class Bridge::RouterWatchTest < ActiveSupport::TestCase
  T0 = Time.utc(2026, 10, 17, 12, 0, 0)

  setup do
    @dir = Dir.mktmpdir
    @now = T0
    @results = [] # what the next probes do: nil (opens) or an error text
    @restarts = []
    @requested = nil
    @busy = false
    @enabled = true
    @logs = []
    @zids = []
  end

  teardown { FileUtils.rm_rf(@dir) }

  def watch(**opts)
    probe = lambda do |_timeout, zid|
      @zids << zid
      r = @results.shift
      raise r if r.is_a?(String)
      sleep r if r.is_a?(Numeric)
    end
    restart = lambda do |reason|
      @restarts << reason
      @requested = @now # bin/relay_restart_request writes restart.request
      [ "asked the router to restart", true ]
    end
    Bridge::RouterWatch.new(every: 30, timeout: 10, fails: 2, grace: 60, probe: probe, restart: restart,
                            requested: -> { @requested }, busy: -> { @busy }, enabled: -> { @enabled },
                            status_path: File.join(@dir, Bridge::RouterWatch::STATUS_FILE),
                            log: ->(t) { @logs << t }, clock: -> { @now }, **opts)
  end

  def step(w, seconds = 30)
    @now += seconds
    w.tick
  end

  def status = Bridge::RouterWatch.status(@dir)

  test "failures in a row restart the router; a passing check in between starts the count again" do
    w = watch
    @results = [ nil, "timeout", nil, "timeout", "timeout" ]
    assert_equal %i[ok failed ok failed restarted], 5.times.map { step(w) }
    assert_equal 1, @restarts.size
    assert_match(/2 checks in a row could not open a new session \(last: RuntimeError: timeout\)/, @restarts.first)
    st = status
    assert_equal [ "restarted", (T0 + 150).iso8601 ], [ st["state"], st["restarted_at"] ]
    assert_match(/last: RuntimeError: timeout/, st["reason"])
    assert @logs.any? { _1.include?("restarting the cloud router: 2 checks in a row") }, @logs.inspect
  end

  test "after a restart request (an apply, its own) nothing is counted for the grace" do
    w = watch
    @requested = T0 + 20 # an apply's restart.request
    @results = [ "refused", "refused", "refused" ]
    assert_equal :quiet, step(w) # 30 s: 10 s after the request
    assert_equal :quiet, step(w) # 60 s: 40 s after
    assert_equal [], @zids, "no probe while zenohd starts"
    assert_equal "quiet", status["state"]
    assert_match(/restart was requested/, status["why"])
    assert_equal %i[failed restarted], [ step(w), step(w) ] # 90 s and 120 s: past the grace
  end

  test "no counting while an apply runs, and a failure before it does not carry over" do
    w = watch
    @results = [ "refused", "refused" ]
    assert_equal :failed, step(w)
    @busy = true
    assert_equal :quiet, step(w)
    @busy = false
    assert_equal :failed, step(w), "the count started again"
    assert_empty @restarts
  end

  test "restarts that do not help wait longer each time, and a passing check resets that" do
    w = watch
    @results = Array.new(40, "refused")
    outcomes = 40.times.map { step(w) }
    restart_at = outcomes.each_index.select { outcomes[_1] == :restarted }.map { (_1 + 1) * 30 }
    # 60 s, then holds of 60, 120, 240, 480 s before the next two failed checks
    assert_equal [ 60, 150, 300, 570, 1080 ], restart_at.first(5)
    assert_equal 5, @restarts.size
    assert w.hold_until > @now
    @results = [ nil ] * 60
    @now = w.hold_until
    assert_equal :ok, step(w)
    assert_equal 0, w.restarts
    @results = [ "refused", "refused" ] + [ nil ] * 10
    assert_equal %i[failed restarted], [ step(w, 61), step(w) ]
    assert_equal 60, (w.hold_until - @now).round, "back to the grace after a check passed"
  end

  test "the hold never goes past MAX_HOLD" do
    w = watch(grace: 600)
    @results = Array.new(400, "refused")
    400.times { step(w) }
    assert_operator @restarts.size, :>=, 5
    assert_operator w.hold_until - @now, :<=, Bridge::RouterWatch::MAX_HOLD
  end

  test "a probe that does not return counts as failed, and is not stacked" do
    w = watch(timeout: 0.05, margin: 0.1)
    @results = [ 0.6 ]
    assert_match(/\Ano answer within 0\.15/, w.check)
    assert_equal "the previous check has not returned yet", w.check
    assert_equal 1, @zids.size, "no second probe while one is stuck"
    sleep 0.7
    @results = [ nil ]
    assert_nil w.check, "the next one runs once the stuck one returned"
  end

  test "errors lose zenoh's source location" do
    e = RuntimeError.new("cannot open a session to tls/zenohd:7448 (-4): Error opening session: Unable to " \
                         "connect to any of [Single(tls/zenohd:7448)]. Timeout! at /home/runner/.cargo/git/" \
                         "checkouts/zenoh-9c599d5ef3e0480e/1211779/zenoh/src/net/runtime/orchestrator.rs:383.")
    assert_equal "RuntimeError: cannot open a session to tls/zenohd:7448 (-4): Error opening session: Unable to " \
                 "connect to any of [Single(tls/zenohd:7448)]. Timeout!", Bridge::RouterWatch.error_text(e)
    assert_equal 300, Bridge::RouterWatch.error_text(RuntimeError.new("x" * 400)).size
  end

  test "0 turns it off; off where the console does not run the cloud router" do
    w = watch(every: 0)
    refute w.on?
    assert_nil w.start!
    assert_equal :off, w.tick
    w = watch
    @enabled = false
    assert_equal :off, step(w)
    assert_empty @zids
  end

  test "settings: defaults, the environment, bad values" do
    assert_equal({ every: 30.0, timeout: 10.0, fails: 2, grace: 60.0 }, Bridge::RouterWatch.settings({}))
    s = Bridge::RouterWatch.settings("ASTERISM_RELAY_WATCH_EVERY" => "0", "ASTERISM_RELAY_WATCH_TIMEOUT" => "5",
                                     "ASTERISM_RELAY_WATCH_FAILS" => "3", "ASTERISM_RELAY_WATCH_GRACE" => "90")
    assert_equal({ every: 0.0, timeout: 5.0, fails: 3, grace: 90.0 }, s)
    assert_equal 1, Bridge::RouterWatch.settings("ASTERISM_RELAY_WATCH_FAILS" => "0")[:fails]
    assert_raises(ArgumentError) { Bridge::RouterWatch.settings("ASTERISM_RELAY_WATCH_EVERY" => "-1") }
    assert_raises(ArgumentError) { Bridge::RouterWatch.settings("ASTERISM_RELAY_WATCH_EVERY" => "soon") }
  end

  test "the probe sessions are named by the watch and hidden from the admin space" do
    w = watch
    @results = [ nil, nil ]
    2.times { step(w) }
    assert_equal 2, @zids.size
    assert(@zids.all? { _1.match?(/\A[1-9a-f][0-9a-f]{31}\z/) }, @zids.inspect)
    assert_equal @zids, w.hidden_zids
    runner = Bridge::Runner.new(objects: Object.new, logger: Logger.new(nil))
    runner.instance_variable_set(:@watch, w)
    admin = { "r1" => { "router" => { "sessions" => [ { "peer" => @zids[0], "whatami" => "client" },
                                                      { "peer" => "abc", "whatami" => "client" } ] },
                        "tokens" => {}, "linkstate" => {} } }
    out = runner.send(:without_probes, admin)
    assert_equal [ "abc" ], out["r1"]["router"]["sessions"].map { _1["peer"] }
  end

  test "the probe opens a client session with the bridge's configuration, named and time-limited" do
    seen = nil
    fake = Class.new do
      define_singleton_method(:open) do |locator, **opts|
        seen = [ locator, opts ]
        Struct.new(:closed) { def close = (self.closed = true) }.new(false)
      end
    end
    stub_const_session(fake) do
      Bridge::RouterWatch.zenoh_probe("tls/zenohd:7448", { "transport/link/tls/enable_mtls" => true }).call(10, "1abc")
      assert_equal "tls/zenohd:7448", seen[0]
      assert_equal({ "transport/link/tls/enable_mtls" => true, "id" => "1abc", "connect/timeout_ms" => 10_000,
                     "transport/unicast/open_timeout" => 10_000 }, seen[1][:config])
      Bridge::RouterWatch.zenoh_probe("tcp/r:7447", nil, config_file: "/etc/z.json5").call(2.5, "1abd")
      assert_equal "/etc/z.json5", seen[1][:config_file]
      assert_equal 2500, seen[1][:config]["connect/timeout_ms"]
    end
  end

  test "the restart request is Apply's (bin/relay_restart_request writes restart.request)" do
    with_generated(@dir) do
      out, ok = Bridge::RouterWatch.apply_restart("test")
      assert ok, out
      assert File.exist?(File.join(@dir, "restart.request"))
      assert_in_delta Time.now, Bridge::RouterWatch.last_request, 5
    end
  end

  test "the last request also counts the newest apply" do
    with_generated(@dir) do
      assert_nil Bridge::RouterWatch.last_request
      RelayApply.create!(status: "ok", mode: "now", started_at: 3.minutes.ago, finished_at: 2.minutes.ago)
      assert_in_delta 2.minutes.ago, Bridge::RouterWatch.last_request, 2
      refute Bridge::RouterWatch.apply_running?
      refute Bridge::RouterWatch.cloud_router_here?
      File.write(File.join(@dir, "cloud.json5"), "{}")
      assert Bridge::RouterWatch.cloud_router_here?
    end
  end

  test "the relay pages show the last automatic restart" do
    with_generated(@dir) do
      assert_nil Bridge::RouterWatch.status(@dir)
      w = watch
      @results = [ "Asterism::Zenoh::Error: cannot open a session", "Asterism::Zenoh::Error: cannot open a session" ]
      2.times { step(w) }
      st = Bridge::RouterWatch.status
      assert_match(/cannot open a session/, st["reason"])
      w2 = watch
      assert_equal st["restarted_at"], w2.restarted_at, "a new bridge keeps the last restart it finds"
    end
  end

  private

  def with_generated(dir)
    old = ENV["ASTERISM_RELAY_GENERATED_DIR"]
    ENV["ASTERISM_RELAY_GENERATED_DIR"] = dir
    yield
  ensure
    ENV["ASTERISM_RELAY_GENERATED_DIR"] = old
  end

  def stub_const_session(fake)
    require "asterism/zenoh"
    old = Asterism::Zenoh::Session
    Asterism::Zenoh.send(:remove_const, :Session)
    Asterism::Zenoh.const_set(:Session, fake)
    yield
  ensure
    Asterism::Zenoh.send(:remove_const, :Session)
    Asterism::Zenoh.const_set(:Session, old)
  end
end
