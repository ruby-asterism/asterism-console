require "test_helper"
require "asterism"
require "socket"
require "rbconfig"

# The Terminal's commands through the real command line (Asterism::CLI on
# the connection given to it) against a CRuby node in another process, over
# a peer link (no router): the listing, a call the permissions allow and
# one they do not, Ctrl-C on a stream, Tab. As the bridge runs them, with
# this process connected as the console.
class Bridge::TerminalLiveTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  PAGE = "page-livelivelivelive"

  NODE = <<~'RUBY'
    require "asterism"
    class Calc
      def add(a, b) = a + b
      def sub(a, b) = a - b
    end
    Asterism.status(tables: 1)
    Asterism.connect(nil, node: "calcnode", app: "calc", mode: :peer, listen: ARGV[0])
    Asterism.expose("calc", Calc.new, methods: { add: { args: %w[a b], doc: "Adds a and b." }, sub: 2 })
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      Asterism.status(tables: line.to_i)
    end
    Asterism.close
  RUBY

  setup do
    skip "this asterism gem cannot run its command line on a connection given (0.13.0)" unless Bridge::Terminal.available?
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    loc = "tcp/127.0.0.1:#{port}"
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    @node = IO.popen([ RbConfig.ruby, *incs, "-e", NODE, loc ], "r+")
    assert_equal "ready", @node.gets&.strip
    Asterism.connect(loc, node: "console", app: "console", mode: :peer)
    Asterism.net.start
    t = Time.now
    sleep 0.05 until Asterism.each("calcnode/**").size == 1 || Time.now - t > 5
    TerminalSession.renew(page: PAGE, user: users(:user))
    @terminal = Bridge::Terminal.new(say: ->(_) { })
  end

  teardown do
    @terminal&.close
    Asterism.close if Asterism.connected?
    if @node
      @node.close_write rescue nil
      @node.read rescue nil
      @node.close rescue nil
    end
  end

  def typed(line, kind: "run")
    TerminalCommand.create!(user: users(:user), page: PAGE, line: line, kind: kind, cols: 60)
  end

  def run_until(timeout = 10)
    t = Time.now
    loop do
      @terminal.tick
      return if yield
      flunk "timed out" if Time.now - t > timeout
      sleep 0.02
    end
  end

  def finished(row)
    run_until { !row.reload.active? }
    row
  end

  def page_output(row)
    broadcasts(ConsoleChannel.terminal_stream(PAGE)).map { ActiveSupport::JSON.decode(_1) }
      .select { _1["type"] == "output" && _1["id"] == row.id }.map { _1["data"] }.join
  end

  test "the command line's commands on the console's connection" do
    c = finished(typed("node list"))
    assert_equal [ "ok", 0 ], [ c.status, c.exit_code ]
    assert_equal "\e[1;34mcalcnode\e[0m\n", page_output(c), "in colour, the console's own node left out"
    c = finished(typed("object info calcnode/calc/calc"))
    assert_match(/add\(a, b\)\s+Adds a and b\./, c.output)

    c = finished(typed("call calcnode/calc/calc add 2 3"))
    assert_equal [ "denied", "call", "add" ], [ c.status, c.effect, c.method_name ], "no call permission"
    CallPermission.create!(node: "calcnode", app: "calc", object: "calc", method_name: "add")
    c = finished(typed("call calcnode/calc/calc add 2 3"))
    assert_equal [ "ok", "5\n" ], [ c.status, c.output ]
    # The line names add, but OptionParser would read --cal as --call: the
    # command line itself refuses an option not written in full.
    c = finished(typed("ping calcnode/calc/calc --count 1 --cal sub 1 2"))
    assert_equal [ "failed", 2 ], [ c.status, c.exit_code ]
    assert_match(/invalid option: --cal/, c.output)
    c = finished(typed("ping calcnode/calc/calc --count 1 --call sub 1 2"))
    assert_equal "denied", c.status

    c = typed("status echo calcnode/calc")
    run_until { page_output(c).include?("tables=1") }
    @node.puts "4"
    @node.flush
    run_until { page_output(c).include?("tables 1→4") }
    c.update!(status: "stopping")
    @terminal.sync
    finished(c)
    assert_equal [ "stopped", "stopped (Ctrl-C)" ], [ c.status, c.reason ]
    assert Asterism.connected?, "the connection stays"

    t = typed("call calcnode/calc/calc a", kind: "complete")
    run_until { !TerminalCommand.exists?(t.id) }
    msg = broadcasts(ConsoleChannel.terminal_stream(PAGE)).map { ActiveSupport::JSON.decode(_1) }.find { _1["type"] == "complete" }
    assert_equal [ "a", [ "add" ] ], msg.values_at("word", "candidates")
  end
end
