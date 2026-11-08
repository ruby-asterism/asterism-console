require "test_helper"
require "asterism/cli/commands"

# The bridge's side of the Terminal (Bridge::Terminal) with a stand-in for
# the command line: the rows it picks up and writes, the output to the
# page's stream, Ctrl-C, a closed page, the limits, Tab, the bridge
# stopping. (The real command line on a real connection:
# terminal_live_test.rb.)
class Bridge::TerminalTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  PAGE = "page-aaaaaaaaaaaaaaaa"

  # Does what its first word says.
  class FakeCLI
    attr_reader :refused

    def initialize(out:, err:, stop:, permit:, log:)
      @out = out
      @err = err
      @stop = stop
      @permit = permit
      @log = log
    end

    def run(argv)
      @log << argv
      case argv[0]
      when "node" then @out.puts "\e[1;34mcalcnode\e[0m"
                       0
      when "watch"
        sleep 0.01 until @stop.call
        @out.puts "stopped"
        0
      when "call"
        why = @permit.call(Asterism::CLI::Plan.new(key: "call", kind: :call, path: argv[1], method: argv[2],
                                                   args: argv[1..], options: {}))
        if why
          @refused = why
          @err.puts "asterism: #{why}"
          return 2
        end
        @out.puts "5"
        0
      when "tree" then raise "broken"
      when "status" then @err.puts "asterism: no status"
                         1
      when "__complete" then @out.puts "list\ninfo\n"
                             0
      end
    end
  end

  setup do
    @log = []
    @said = []
    @terminal = Bridge::Terminal.new(say: ->(t) { @said << t }, cli: lambda { |**kw| FakeCLI.new(**kw, log: @log) })
    TerminalSession.renew(page: PAGE, user: users(:user))
  end

  teardown { @terminal.close }

  def command(line, page: PAGE, user: users(:user), kind: "run")
    TerminalCommand.create!(user: user, page: page, line: line, kind: kind, cols: 100)
  end

  def run_until(timeout = 3)
    t = Time.now
    loop do
      @terminal.tick
      return if yield
      flunk "timed out" if Time.now - t > timeout
      sleep 0.02
    end
  end

  def stream_messages
    broadcasts(ConsoleChannel.terminal_stream(PAGE)).map { ActiveSupport::JSON.decode(_1) }
  end

  test "a command runs, its output goes to its page, the row says how it ended" do
    c = command("asterism node list")
    run_until { c.reload.status == "ok" }
    assert_equal [ %w[node list] ], @log
    msgs = stream_messages
    assert_equal [ "started", "output", "done" ], msgs.map { _1["type"] }
    assert_equal "\e[1;34mcalcnode\e[0m\n", msgs[1]["data"], "colours as the command line paints them"
    assert_equal [ "ok", 0, "calcnode\n", 20 ], [ c.status, c.exit_code, c.output, c.output_bytes ]
    assert c.took_ms
    assert_equal "ok", msgs[2]["status"]
  end

  test "a failed command, and one that raises" do
    c = command("status get a/b")
    run_until { c.reload.status != "running" && c.status != "pending" }
    assert_equal [ "failed", 1, "asterism: no status\n" ], [ c.status, c.exit_code, c.output ]
    c = command("tree")
    run_until { c.reload.status == "failed" }
    assert_equal "RuntimeError: broken", c.reason
  end

  test "the bridge reads the line again, and the command line's own plan is asked" do
    c = TerminalCommand.create!(user: users(:user), page: PAGE, line: "ls /", cols: 80) # past the page
    run_until { c.reload.status == "denied" }
    assert_empty @log
    assert_match(/not an asterism command/, c.reason)
    CallPermission.create!(node: "*", app: "*", object: "*", method_name: "add")
    c = command("call a/b/c add 2 3")
    run_until { c.reload.status == "ok" }
    assert_equal [ "call", "call", "a/b/c", "add", "5\n" ], [ c.command, c.effect, c.path, c.method_name, c.output ]
    CallPermission.delete_all
    CallPermission.create!(node: "*", app: "*", object: "*", method_name: "add")
    # The line names add, the command line read sub (as an option written
    # short would make it): its plan decides.
    @terminal.instance_variable_set(:@cli, lambda { |**kw|
      FakeCLI.new(**kw, log: @log).tap { |f| f.define_singleton_method(:run) { |_argv| super(%w[call a/b/c sub]) } }
    })
    c = command("call a/b/c add")
    run_until { c.reload.status == "denied" }
    assert_match(/no call permission allows a\/b\/c sub/, c.reason)
    assert_equal "sub", c.method_name, "the row says what the command line would have called"
  end

  test "Ctrl-C stops a stream" do
    c = command("watch")
    run_until { c.reload.status == "running" && @terminal.running == 1 }
    c.update!(status: "stopping")
    @terminal.sync
    run_until { c.reload.status == "stopped" }
    assert_equal "stopped (Ctrl-C)", c.reason
    assert_equal "stopped\n", c.output
  end

  test "closing the page stops what it runs" do
    c = command("watch")
    run_until { @terminal.running == 1 }
    TerminalSession.release(page: PAGE, user: users(:user))
    @terminal.sync
    run_until { c.reload.status == "stopped" }
    assert_equal "stopped: the page was closed", c.reason
  end

  test "at most PER_USER of a user's at once; the others wait" do
    n = Bridge::Terminal::PER_USER
    rows = (n + 1).times.map do |i|
      page = "page-#{i}-aaaaaaaaaaaaaaaa"
      TerminalSession.renew(page: page, user: users(:user))
      command("watch", page: page)
    end
    TerminalSession.renew(page: "page-admin-aaaaaaaaaaaa", user: users(:admin))
    other = command("watch", page: "page-admin-aaaaaaaaaaaa", user: users(:admin))
    run_until { @terminal.running == n + 1 }
    assert_equal [ "running" ] * n + [ "pending" ], rows.map { _1.reload.status }
    assert_equal "running", other.reload.status
  end

  test "Tab: the candidates to the page, the row removed" do
    c = command("node l", kind: "complete")
    run_until { !TerminalCommand.exists?(c.id) }
    assert_equal [ %w[__complete -- node l] ], @log
    msg = stream_messages.last
    assert_equal [ "complete", c.id, "l", %w[list info] ], msg.values_at("type", "id", "word", "candidates")
  end

  test "rows nobody picked up expire" do
    c = command("watch")
    c.update_columns(created_at: 1.minute.ago)
    t = command("node", kind: "complete")
    t.update_columns(created_at: 1.minute.ago)
    @terminal.sync
    assert_equal "expired", c.reload.status
    refute TerminalCommand.exists?(t.id)
  end

  test "the bridge stopping stops them; a bridge starting finishes what one left" do
    c = command("watch")
    run_until { @terminal.running == 1 }
    @terminal.close
    assert_equal [ "stopped", "the bridge stopped (or lost its router)" ], [ c.reload.status, c.reason ]
    left = command("watch")
    left.update!(status: "running")
    Bridge::Terminal.new(say: ->(_) { }).start
    assert_equal [ "stopped", "the bridge stopped while it ran" ], [ left.reload.status, left.reason ]
  end

  test "what may run: the command line's plan against the permissions" do
    plan = ->(**kw) { Asterism::CLI::Plan.new(key: "call", kind: :call, options: {}, **kw) }
    rows = [ CallPermission.new(node: "a", app: "b", object: "c", method_name: "ok") ]
    assert_nil Bridge::Terminal.refusal(plan.(path: "a/b/c", method: "ok"), rows)
    assert_match(/no call permission allows a\/b\/c no/, Bridge::Terminal.refusal(plan.(path: "a/b/c", method: "no"), rows))
    assert_match(/no call permission/, Bridge::Terminal.refusal(plan.(path: nil, method: nil), rows))
    assert_match(/runs only as a program/, Bridge::Terminal.refusal(Asterism::CLI::Plan.new(key: "mcp", kind: :local), rows))
    read = Asterism::CLI::Plan.new(key: "tree", kind: :read, options: { timeout: 2.0 })
    assert_nil Bridge::Terminal.refusal(read, [])
    read.options = { timeout: 31.0 }
    assert_match(/at most 30 s/, Bridge::Terminal.refusal(read, []))
    read.options = { put_timeout: 60.0 }
    assert_match(/at most 30 s/, Bridge::Terminal.refusal(read, []))
  end

  test "the output: a terminal's width, cut where a character ends, bounded" do
    o = Bridge::Terminal::Output.new(cols: 120, limit: 10)
    assert o.tty?
    assert_equal [ 24, 120 ], o.winsize
    o.write("ab", "あ") # 2 + 3 bytes
    assert_equal "ab", o.take(4), "the character cut is kept for the next"
    assert_equal "あ", o.take(4)
    o.puts("123456789")
    assert o.over?
    assert_equal "12345", o.take
    assert_equal 10, o.total
    o = Bridge::Terminal::Output.new
    o.puts
    o.puts([ "a", [ "b" ] ], nil)
    o.print "c"
    o << "d"
    assert_equal "\na\nb\n\ncd", o.take
  end
end
