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

  teardown do
    @terminal.close
    FileUtils.rm_rf(@files_dir) if @files_dir
    ENV.delete("ASTERISM_RSHELL_FILES_DIR")
  end

  # get and put keep their files in a directory of their own here.
  def files_dir
    @files_dir ||= Dir.mktmpdir("rshell_files").tap { ENV["ASTERISM_RSHELL_FILES_DIR"] = _1 }
  end

  Upload = Struct.new(:original_filename, :path, :size)

  # The files a page chose for put, as Rails keeps them: the token.
  def uploaded(files, user: users(:user))
    files_dir
    dir = Dir.mktmpdir("up", @files_dir)
    ups = files.map do |name, data|
      path = File.join(dir, name.tr("/", "_"))
      File.binwrite(path, data)
      Upload.new(name, path, data.bytesize)
    end
    TerminalFiles.new_put(user_id: user.id, page: PAGE, files: ups)
  end

  def put_line(text, token, **kw)
    finished(TerminalCommand.create!(user: users(:user), page: PAGE, line: text, kind: "run", cols: 100, remote: NODE,
                                     files: JSON.generate("upload" => token), **kw))
  end

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

  test "get: the file's bytes to the console's place, a link for the page, once for its user" do
    files_dir
    bin = (0..255).map(&:chr).join.b * 100 # 25600 bytes, every byte
    @machine.files["/home/pic.png"] = bin
    users(:user).update!(rshell_access: "read")
    enter
    r = line("get pic.png")
    assert_equal [ "ok", 0, "get", "read" ], [ r.status, r.exit_code, r.command, r.effect ]
    assert_equal [ 0, 8192, 16384, 24576 ], @machine.calls.select { _1[0] == "read" }.map(&:last)
    d = messages.find { _1["type"] == "download" && _1["id"] == r.id }
    assert_equal "pic.png", d["name"]
    token = d["url"].delete_prefix("/terminal/files/")
    assert_match(/get \/home\/pic.png: 25 KB \(25600 bytes\); the browser saves it as pic.png/, output(r))
    assert_equal [ { "path" => "/home/pic.png", "size" => 25600, "got" => 25600, "result" => "ok" } ], r.files_value["files"]
    assert_nil TerminalFiles.take_get(token, users(:admin)), "another user's link"
    f = TerminalFiles.take_get(token, users(:user))
    assert_equal [ "pic.png", bin ], [ f["name"], f["data"] ]
    assert_nil TerminalFiles.take_get(token, users(:user)), "once"
  end

  test "get refuses a folder, a secret, a file over the limit, with the reason" do
    files_dir
    enter
    r = line("get apps")
    assert_equal "denied", r.status
    assert_match(%r{/home/apps: not a file}, r.reason)
    secret = line("get /home/asterism/config.toml")
    assert_match(/kept from the remote shell/, secret.reason)
    assert_no_match(/#{NODE}: #{NODE}:/, output(secret), "the machine's name once")
    @machine.files["/home/big.bin"] = "x" * 20
    rs = Bridge::RemoteShell.new(call: @rshell.instance_variable_get(:@call))
    s = @terminal.instance_variable_get(:@remotes)[PAGE]
    e = assert_raises(Bridge::RemoteShell::Refused) { rs.get(s, "big.bin", to: File.join(files_dir, "x"), out: StringIO.new, max: 10) }
    assert_match(/over the console's limit/, e.message)
    assert_empty Dir.children(File.join(files_dir, "get")), "no place left behind"
    refute messages.any? { _1["type"] == "download" }
  end

  test "get stopped by Ctrl-C keeps nothing" do
    files_dir
    @machine.files["/home/large.bin"] = "y" * 200_000
    enter
    slow = @rshell.instance_variable_get(:@call)
    @terminal.instance_variable_set(:@rshell, Bridge::RemoteShell.new(call: ->(*a, **k) { sleep 0.01; slow.call(*a, **k) }))
    r = typed("get large.bin", remote: NODE)
    run_until { @machine.calls.count { _1[0] == "read" } >= 3 }
    r.update!(status: "stopping")
    @terminal.sync
    finished(r)
    assert_equal "stopped", r.status
    assert_match(/stopped at/, output(r))
    assert_empty Dir.children(File.join(files_dir, "get"))
  end

  test "put: the uploaded files into where the session is, piece by piece" do
    bin = (0..255).map(&:chr).join.b * 80 # 20480 bytes
    token = uploaded([ [ "a.bin", bin ], [ "かな.txt", "かな\n" ] ])
    enter
    r = put_line("put", token)
    assert_equal [ "ok", 0, "put", "write" ], [ r.status, r.exit_code, r.command, r.effect ]
    assert_equal bin, @machine.files["/home/a.bin"]
    assert_equal "かな\n".b, @machine.files["/home/かな.txt"]
    assert_equal [ 0, 8192, 16384 ], @machine.calls.select { _1[0] == "write_chunk" }.first(3).map { _1[1] }
    assert_equal %w[/home/a.bin /home/かな.txt], r.files_value["files"].map { _1["path"] }
    assert_match(%r{put /home/a.bin: 20 KB \(20480 bytes\)}, output(r))
    assert_nil TerminalFiles.put_files(token, users(:user)), "the upload goes once sent"
  end

  test "put into a folder given, or as the file given; several files want a folder" do
    enter
    assert_equal "ok", put_line("put apps", uploaded([ [ "x.txt", "x" ] ])).status
    assert_equal "x", @machine.files["/home/apps/x.txt"]
    assert_equal "ok", put_line("put renamed.txt", uploaded([ [ "y.txt", "y" ] ])).status
    assert_equal "y", @machine.files["/home/renamed.txt"]
    r = put_line("put one.txt", uploaded([ [ "p.txt", "p" ], [ "q.txt", "q" ] ]))
    assert_equal "denied", r.status
    assert_match(/not a folder on #{NODE} \(2 files go into a folder\)/, r.reason)
  end

  test "put: a name there is asked about; y sends it again with the same upload and writes over" do
    enter
    token = uploaded([ [ "notes.txt", "new\n" ] ])
    r = put_line("put", token)
    assert_equal "asked", r.status
    d = done(r)
    assert_match(%r{/home/notes.txt is there already \(written over\)\. Go on\? \(y/N\)}, d["confirm"])
    assert_equal token, d["upload"]
    assert_equal "hello\n", @machine.files["/home/notes.txt"], "not sent"
    r = put_line("put", token, confirmed: true)
    assert_equal "ok", r.status
    assert_equal "new\n", @machine.files["/home/notes.txt"]
    assert_equal true, @machine.calls.find { _1[0] == "write_begin" }[3]
  end

  test "put into the system's area is asked about too" do
    enter
    r = put_line("put /etc", uploaded([ [ "z.toml", "z" ] ]))
    assert_equal "asked", r.status
    assert_match(/\/etc is in the system's area/, done(r)["confirm"])
  end

  test "put: the machine's refusals per file, a read-only user, another user's upload, an older machine" do
    enter
    @machine.read_only << "/home/ro"
    r = put_line("put /home/ro/", uploaded([ [ "a.txt", "a" ] ]))
    assert_equal [ "failed", 1 ], [ r.status, r.exit_code ]
    assert_match(/read-only here/, output(r))
    assert_equal [ "refused" ], r.files_value["files"].map { _1["result"] }
    assert_equal "write_cancel", @machine.calls.last[0]
    r = put_line("put", uploaded([ [ "b.txt", "b" ] ], user: users(:admin)))
    assert_match(/no files came with the line/, r.reason)
    users(:user).update!(rshell_access: "read")
    r = put_line("put", uploaded([ [ "c.txt", "c" ] ]))
    assert_match(/put: changes the machine; you may only read/, r.reason)
    users(:user).update!(rshell_access: "write")
    line("exit")
    @machine.version = 2
    enter
    r = put_line("put", uploaded([ [ "d.txt", "d" ] ]))
    assert_match(/remote shell is version 2; put needs 3/, r.reason)
  end

  test "put stopped by Ctrl-C: the machine drops its piece file" do
    token = uploaded([ [ "large.bin", "z" * 200_000 ] ])
    enter
    slow = @rshell.instance_variable_get(:@call)
    @terminal.instance_variable_set(:@rshell, Bridge::RemoteShell.new(call: ->(*a, **k) { sleep 0.01; slow.call(*a, **k) }))
    r = TerminalCommand.create!(user: users(:user), page: PAGE, line: "put", kind: "run", cols: 100, remote: NODE,
                                files: JSON.generate("upload" => token))
    run_until { @machine.calls.count { _1[0] == "write_chunk" } >= 3 }
    r.update!(status: "stopping")
    @terminal.sync
    finished(r)
    assert_equal "stopped", r.status
    assert_equal "write_cancel", @machine.calls.last[0]
    assert_nil @machine.pending
    refute @machine.files.key?("/home/large.bin")
  end

  test "Tab offers get and put as the first word; their arguments are the machine's paths" do
    enter
    t = typed("g", kind: "complete", remote: NODE)
    run_until { !TerminalCommand.exists?(t.id) }
    assert_equal [ "get" ], messages.select { _1["type"] == "complete" }.last["candidates"]
    t = typed("p", kind: "complete", remote: NODE)
    run_until { !TerminalCommand.exists?(t.id) }
    assert_equal %w[ps put pwd], messages.select { _1["type"] == "complete" }.last["candidates"]
    t = typed("get my", kind: "complete", remote: NODE)
    run_until { !TerminalCommand.exists?(t.id) }
    assert_equal [ "my\\ file.txt" ], messages.select { _1["type"] == "complete" }.last["candidates"]
  end

  test "a long cp: the progress on one line, Ctrl-C asks the machine to stop" do
    enter
    waits = 0
    base = @rshell.instance_variable_get(:@call)
    call = lambda do |node, method, *args, timeout:|
      case method
      when "exec_write"
        { "out" => "cp: a -> b: copying 1 MB\n", "code" => 0, "cwd" => "/home", "more" => 25, "wait" => true }
      when "more"
        waits += 1
        if waits < 3
          { "out" => "", "more" => 25, "wait" => true, "code" => nil, "progress" => { "done" => waits * 4096, "total" => 1_048_576 } }
        else
          { "out" => "cp: a -> b (1048576 bytes)\n", "more" => nil, "wait" => false, "code" => 0 }
        end
      else base.call(node, method, *args, timeout: timeout)
      end
    end
    @terminal.instance_variable_set(:@rshell, Bridge::RemoteShell.new(call: call, sleep: ->(_) { }))
    @terminal.instance_variable_get(:@remotes)[PAGE].version = 3
    r = line("cp a b")
    assert_equal "ok", r.status
    assert_includes output(r), "\r\e[K  4 KB / 1024 KB"
    assert output(r).end_with?("\r\e[Kcp: a -> b (1048576 bytes)\n")
  end

  test "a machine whose transfer app is not running is not called (the call would only wait)" do
    @rshell.define_singleton_method(:transfer?) { |_n| false }
    r = enter
    assert_equal "denied", r.status
    assert_match(/the remote shell is off on #{NODE} \(its transfer app/, r.reason)
    assert_empty @machine.calls
  end
end
