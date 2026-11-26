require "test_helper"
require "asterism"
require_relative "../../test_helpers/fake_rshell"

# The bridge's side of the remote shell (Bridge::Terminal with
# Bridge::RemoteShell) against a stand-in machine (FakeRShell, called
# directly): going in, a line and its output piece by piece, kill's result
# through more, Ctrl-C between the calls, Tab, exit, the page closing, one
# page per machine, the permissions read again, the question about the
# system's area, the machine's refusals, the bridge stopping and starting.
class Bridge::TerminalRemoteTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  PAGE = "page-remoteremoteremo"
  OTHER = "page-otherotherotherr"
  NODE = "fmruby-aaaaaa"

  setup do
    @machine = FakeRShell.new(NODE)
    @present = true
    call = lambda do |node, method, *args, timeout:|
      raise Asterism::TimeoutError, "no answer" unless node == NODE
      @machine.public_send(method, *args, from: "console")
    rescue ArgumentError => e
      raise Asterism::RemoteError.new("ArgumentError", e.message, "raised")
    end
    @rshell = Bridge::RemoteShell.new(call: call, sleep: ->(_) { })
    @rshell.define_singleton_method(:present?) { |_n| true }
    @rshell.define_singleton_method(:nodes) { [ NODE ] }
    @terminal = Bridge::Terminal.new(say: ->(_) { }, cli: ->(**) { flunk "no command line in a machine" }, rshell: @rshell)
    users(:user).update!(rshell_access: "write")
    TerminalSession.renew(page: PAGE, user: users(:user))
  end

  teardown { @terminal.close }

  def typed(line, page: PAGE, user: users(:user), kind: "run", remote: nil, command: nil, confirmed: false)
    TerminalCommand.create!(user: user, page: page, line: line, kind: kind, cols: 100, remote: remote,
                            command: command, confirmed: confirmed)
  end

  def run_until(timeout = 3)
    t = Time.now
    loop do
      @terminal.tick
      return if yield
      flunk "timed out" if Time.now - t > timeout
      sleep 0.01
    end
  end

  def finished(row)
    run_until { !row.reload.active? }
    row
  end

  def messages(page = PAGE)
    broadcasts(ConsoleChannel.terminal_stream(page)).map { ActiveSupport::JSON.decode(_1) }
  end

  def output(row, page = PAGE)
    messages(page).select { _1["type"] == "output" && _1["id"] == row.id }.map { _1["data"] }.join
  end

  def done(row, page = PAGE)
    messages(page).find { _1["type"] == "done" && _1["id"] == row.id }
  end

  def enter(page = PAGE, user = users(:user))
    finished(typed("remote #{NODE}", page: page, user: user, remote: NODE, command: "remote"))
  end

  def line(text, **kw)
    finished(typed(text, remote: NODE, **kw))
  end

  test "remote <node> goes in: the session stays in the bridge, Rails gets the machine and its table" do
    r = enter
    assert_equal "ok", r.status
    assert_equal({ "node" => NODE, "cwd" => "/home" }, done(r)["remote"])
    v = TerminalSession.find_by(page: PAGE).remote_value
    assert_equal [ NODE, "/home", "read" ], [ v["node"], v["cwd"], v.dig("commands", "ls") ]
    refute TerminalSession.find_by(page: PAGE).remote.include?("\"id\""), "the session number stays in the bridge"
    assert_equal({ PAGE => NODE }, @terminal.remotes)
  end

  test "remote alone lists the machines whose remote shell is on" do
    r = finished(typed("remote", command: "remote"))
    assert_equal [ "ok", "#{NODE}\n" ], [ r.status, output(r) ]
    enter
    r = finished(typed("remote", page: PAGE, command: "remote"))
    assert_equal "#{NODE}  (this page is in it)\n", output(r)
  end

  test "a line, its output piece by piece, where it is after it" do
    enter
    r = line("cat big.txt")
    assert_equal [ "ok", 0, "read", "exec_read" ], [ r.status, r.exit_code, r.effect, @machine.calls.first[0] ]
    assert_equal @machine.files["/home/big.txt"], output(r), "the first answer and two more"
    assert_equal [ [ "more", 8192 ], [ "more", 16384 ] ], @machine.calls.select { _1[0] == "more" }
    assert_equal 20000, r.output_bytes
    line("cd /tmp")
    assert_equal "/tmp", TerminalSession.find_by(page: PAGE).remote_value["cwd"]
    r = line("cat nothing")
    assert_equal [ "failed", 1 ], [ r.status, r.exit_code ]
    assert_equal({ "node" => NODE, "cwd" => "/tmp" }, done(r)["remote"])
  end

  test "write lines go to exec_write; kill's result comes through more" do
    enter
    r = line("rm notes.txt")
    assert_equal [ "ok", [ "exec_write", "rm notes.txt" ] ], [ r.status, @machine.calls.last ]
    refute @machine.files.key?("/home/notes.txt")
    r = line("kill 7")
    assert_equal "kill: asked the kernel to end PID 7 (demo)\nkill: PID 7 ended\n", output(r)
    assert_equal [ "ok", 0 ], [ r.status, r.exit_code ]
    assert_equal 3, @machine.calls.count { _1[0] == "more" }, "asked again while it waited"
  end

  test "Ctrl-C between the calls" do
    enter
    @machine.kill_waits = 1000
    sleeper = Bridge::RemoteShell.new(call: @rshell.instance_variable_get(:@call), sleep: ->(_) { sleep 0.02 })
    @terminal.instance_variable_set(:@rshell, sleeper)
    r = typed("kill 7", remote: NODE)
    run_until { output(r).include?("asked") }
    r.update!(status: "stopping")
    @terminal.sync
    finished(r)
    assert_equal [ "stopped", "stopped (Ctrl-C)" ], [ r.status, r.reason ]
    assert_equal({ PAGE => NODE }, @terminal.remotes, "still in the machine")
  end

  test "the permission is read again before a line is sent" do
    enter
    users(:user).update!(rshell_access: "read")
    r = line("rm notes.txt")
    assert_equal "denied", r.status
    assert_match(/you may only read .*checked by the bridge/, r.reason)
    assert @machine.files.key?("/home/notes.txt"), "not sent"
    assert line("ls").status == "ok"
    users(:user).update!(rshell_access: "none")
    assert_equal "denied", line("ls").status
    assert_equal "ok", line("exit").status, "leaving is always possible"
  end

  test "a change of the system's area is asked about; sent once confirmed" do
    enter
    r = line("rm ../etc/system_conf.toml")
    assert_equal "asked", r.status
    d = done(r)
    assert_match(%r{/etc/system_conf.toml is in the system's area of #{NODE} .*\(y/N\)}, d["confirm"])
    assert @machine.files.key?("/etc/system_conf.toml"), "not sent"
    r = line("rm ../etc/system_conf.toml", confirmed: true)
    assert_equal "ok", r.status
    refute @machine.files.key?("/etc/system_conf.toml")
  end

  test "Tab asks the machine; the candidates come as it typed them" do
    enter
    t = typed("cat my", kind: "complete", remote: NODE)
    run_until { !TerminalCommand.exists?(t.id) }
    msg = messages.find { _1["type"] == "complete" }
    assert_equal [ true, 4, [ "my\\ file.txt" ] ], msg.values_at("remote", "start", "candidates")
    t = typed("l", kind: "complete", remote: NODE)
    run_until { !TerminalCommand.exists?(t.id) }
    assert_equal [ 0, [ "ls" ] ], messages.select { _1["type"] == "complete" }.last.values_at("start", "candidates")
  end

  test "exit closes the session; the page closing too, with the exit in the record" do
    enter
    r = line("exit")
    assert_equal [ "ok", "close" ], [ r.status, r.effect ]
    assert_nil done(r)["remote"]
    assert_equal [ 1 ], @machine.closed
    assert_nil TerminalSession.find_by(page: PAGE).remote
    assert_empty @terminal.remotes

    enter
    TerminalSession.release(page: PAGE, user: users(:user))
    @terminal.sync
    t = Time.now
    sleep 0.01 until @machine.closed.size == 2 || Time.now - t > 3
    assert_equal [ 1, 2 ], @machine.closed
    row = TerminalCommand.where(remote: NODE, command: "exit").order(:id).last
    assert_equal [ "ok", "the page was closed", users(:user).id ], [ row.status, row.reason, row.user_id ]
    assert_empty @terminal.remotes
  end

  test "one page at a time in a machine" do
    enter
    TerminalSession.renew(page: OTHER, user: users(:admin))
    users(:admin).update!(rshell_access: "read")
    r = enter(OTHER, users(:admin))
    assert_equal "denied", r.status
    assert_match(/another user of the console is in #{NODE}/, r.reason)
    TerminalSession.renew(page: "page-mineminemineminem", user: users(:user))
    r = enter("page-mineminemineminem")
    assert_match(/you are in #{NODE} on another Terminal page/, r.reason)
    r = finished(typed("remote fmruby-bbbbbb", remote: "fmruby-bbbbbb", command: "remote"))
    assert_match(/this page is in #{NODE}/, r.reason)
  end

  test "the machine's refusals in the user's words" do
    @machine.allow = []
    r = enter
    assert_equal "denied", r.status
    assert_match(/does not let this console in .*\(#{NODE} lets no remote shell in from console/, r.reason)
    assert_match(/does not let this console in/, output(r))
    assert_nil done(r)["remote"]
    assert_empty @terminal.remotes
    r = finished(typed("remote fmruby-gone", remote: "fmruby-gone", command: "remote"))
    assert_match(/fmruby-gone did not answer open in 10 s/, r.reason)
  end

  test "a session the machine ended: the page leaves it" do
    enter
    @machine.close(1, from: "console")
    r = line("ls")
    assert_equal "denied", r.status
    assert_match(/the session on #{NODE} has ended/, r.reason)
    assert_nil done(r)["remote"]
    assert_nil TerminalSession.find_by(page: PAGE).remote
  end

  test "a line for a session the bridge does not hold (it restarted)" do
    TerminalSession.set_remote(PAGE, { "node" => NODE, "commands" => { "ls" => "read" }, "cwd" => "/home" })
    @terminal.start
    assert_nil TerminalSession.find_by(page: PAGE).remote, "a bridge that starts clears the copies"
    r = line("ls")
    assert_equal "denied", r.status
    assert_match(/has ended/, r.reason)
  end

  test "the bridge stopping closes the sessions and records the exit" do
    enter
    @terminal.close
    assert_equal [ 1 ], @machine.closed
    assert_equal "the bridge stopped", TerminalCommand.where(command: "exit").last.reason
  end

  test "a user without the permission does not go in, even with a row" do
    users(:user).update!(rshell_access: "none")
    r = enter
    assert_equal "denied", r.status
    assert_match(/may not use the remote shell/, r.reason)
    assert_empty @machine.calls
  end

  test "a machine whose transfer app is not running is not called (the call would only wait)" do
    @rshell.define_singleton_method(:transfer?) { |_n| false }
    r = enter
    assert_equal "denied", r.status
    assert_match(/the remote shell is off on #{NODE} \(its transfer app/, r.reason)
    assert_empty @machine.calls
  end
end
