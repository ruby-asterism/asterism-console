require "test_helper"
require "asterism"
require "socket"
require "rbconfig"

# The remote shell through the real object layer: a CRuby node in another
# process exposes a stand-in machine's remote shell (FakeRShell as
# <node>/transfer/rshell, caller: :from, the answers of the machine's
# report) over a peer link, and the bridge's Terminal calls it as the
# console (Bridge::RemoteShell on the connection): the list, going in, a
# line with more, kill's result, Tab with a blank in a name, exit, the page
# closing, and a machine whose remote shell is off (no such object).
class Bridge::TerminalRemoteLiveTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  PAGE = "page-rshelllivelivel"
  NODE = "fmruby-aaaaaa"

  MACHINE = <<~'RUBY'
    require "asterism"
    require ARGV[1]
    net = Asterism.connect(nil, node: "fmruby-aaaaaa", app: "transfer", mode: :peer, listen: ARGV[0])
    rshell = FakeRShell.new("fmruby-aaaaaa")
    inbox = Object.new
    def inbox.ping = true
    net.expose("inbox", inbox, methods: { ping: 0 })
    net.expose("rshell", rshell, methods: FakeRShell::METHODS, caller: :from)
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      net.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      if line.strip == "off"
        net.unexpose("rshell")
      else
        STDOUT.puts rshell.closed.inspect
        STDOUT.flush
      end
    end
    net.close
  RUBY

  setup do
    skip "this asterism gem cannot run its command line on a connection given (0.13.0)" unless Bridge::Terminal.available?
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    loc = "tcp/127.0.0.1:#{port}"
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    fake = Rails.root.join("test/test_helpers/fake_rshell.rb").to_s
    @node = IO.popen([ RbConfig.ruby, *incs, "-e", MACHINE, loc, fake ], "r+")
    assert_equal "ready", @node.gets&.strip
    @net = Asterism.connect(loc, node: "console", app: "console", mode: :peer)
    @net.start
    t = Time.now
    sleep 0.05 until @net.each("#{NODE}/**").size == 2 || Time.now - t > 5
    users(:user).update!(rshell_access: "write")
    TerminalSession.renew(page: PAGE, user: users(:user))
    @terminal = Bridge::Terminal.new(say: ->(_) { }, net: -> { @net })
  end

  teardown do
    @terminal&.close
    @net&.close
    if @node
      @node.close_write rescue nil
      @node.read rescue nil
      @node.close rescue nil
    end
  end

  def typed(line, kind: "run", remote: nil, command: nil)
    TerminalCommand.create!(user: users(:user), page: PAGE, line: line, kind: kind, cols: 80, remote: remote, command: command)
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

  def messages
    broadcasts(ConsoleChannel.terminal_stream(PAGE)).map { ActiveSupport::JSON.decode(_1) }
  end

  def output(row)
    messages.select { _1["type"] == "output" && _1["id"] == row.id }.map { _1["data"] }.join
  end

  def closed_on_machine
    @node.puts "closed?"
    @node.flush
    eval(@node.gets.to_s) # rubocop:disable Security/Eval -- an Array's inspect from the test's own child
  end

  test "into the machine and out, on the object layer" do
    r = finished(typed("remote", command: "remote"))
    assert_equal "#{NODE}\n", output(r)

    r = finished(typed("remote #{NODE}", remote: NODE, command: "remote"))
    assert_equal "ok", r.status, r.reason
    assert_equal({ PAGE => NODE }, @terminal.remotes)

    r = finished(typed("cat big.txt", remote: NODE))
    assert_equal [ "ok", 20000 ], [ r.status, output(r).bytesize ]
    r = finished(typed("kill 7", remote: NODE))
    assert_match(/asked the kernel.*\nkill: PID 7 ended\n\z/, output(r))

    t = typed("cat my", kind: "complete", remote: NODE)
    run_until { !TerminalCommand.exists?(t.id) }
    assert_equal [ 4, [ "my\\ file.txt" ] ], messages.find { _1["type"] == "complete" }.values_at("start", "candidates")
    r = finished(typed("cat my\\ file.txt", remote: NODE))
    assert_equal "spaced\n", output(r)

    r = finished(typed("exit", remote: NODE))
    assert_equal "ok", r.status
    assert_equal [ 1 ], closed_on_machine

    finished(typed("remote #{NODE}", remote: NODE, command: "remote"))
    TerminalSession.release(page: PAGE, user: users(:user))
    @terminal.sync
    t = Time.now
    sleep 0.05 until closed_on_machine == [ 1, 2 ] || Time.now - t > 5
    assert_equal [ 1, 2 ], closed_on_machine, "the page closed: the session too"
  end

  test "a machine whose remote shell is off" do
    @node.puts "off"
    @node.flush
    t = Time.now
    sleep 0.05 until @net.each("#{NODE}/**").size == 1 || Time.now - t > 5
    TerminalSession.renew(page: PAGE, user: users(:user))
    r = finished(typed("remote #{NODE}", remote: NODE, command: "remote"))
    assert_equal "denied", r.status
    assert_match(/the remote shell is off on #{NODE} .*no object rshell exposed/, r.reason)
    r = finished(typed("remote fmruby-nobody", remote: "fmruby-nobody", command: "remote"))
    assert_match(/fmruby-nobody is not on the network now/, r.reason)
  end
end
