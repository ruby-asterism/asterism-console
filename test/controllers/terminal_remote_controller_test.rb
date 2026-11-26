require "test_helper"

# The remote shell's requests (Rails' side, docs/terminal.md): remote and
# remote <node> by the user's permission, the lines while the page is in a
# machine (its TerminalSession's remote, written by the bridge) by the
# machine's table and the permission, where the page believes it is, Tab,
# and the record.
class TerminalRemoteControllerTest < ActionDispatch::IntegrationTest
  PAGE = "page-rrrrrrrrrrrrrrrr"
  COMMANDS = { "ls" => "read", "cat" => "read", "rm" => "write", "kill" => "write" }.freeze

  setup do
    sign_in_as(users(:user))
    post lease_terminal_path, params: { page: PAGE }, as: :json
    assert_response :success
  end

  def run_line(line, remote: nil, **more)
    post commands_terminal_path, params: { page: PAGE, line: line, cols: 100, remote: remote.to_s, **more }, as: :json
    response.parsed_body
  end

  # As the bridge writes it when the machine let the page in.
  def inside(node = "fmruby-aaaaaa", cwd: "/home")
    TerminalSession.set_remote(PAGE, { "node" => node, "commands" => COMMANDS, "cwd" => cwd })
  end

  test "remote needs the user's remote shell permission (none by default, admins too)" do
    assert_equal "none", users(:user).rshell_access
    assert_equal "none", users(:admin).rshell_access
    body = run_line("remote fmruby-aaaaaa")
    assert_response :forbidden
    assert_match(/you may not use the remote shell/, body["reason"])
    row = TerminalCommand.find(body["id"])
    assert_equal [ "denied", "remote", "open", "fmruby-aaaaaa" ], [ row.status, row.command, row.effect, row.remote ]
    run_line("remote")
    assert_response :forbidden
  end

  test "remote <node> and remote alone go to the bridge" do
    users(:user).update!(rshell_access: "read")
    body = run_line("remote fmruby-aaaaaa")
    assert_response :created
    row = TerminalCommand.find(body["id"])
    assert_equal [ "pending", "remote", "open", "fmruby-aaaaaa", "fmruby-aaaaaa/transfer/rshell", "open" ],
                 [ row.status, row.command, row.effect, row.remote, row.path, row.method_name ]
    row.update!(status: "ok")
    body = run_line("remote")
    assert_response :created
    assert_equal [ "remote", "read", nil ], TerminalCommand.find(body["id"]).then { [ _1.command, _1.effect, _1.remote ] }
    TerminalCommand.update_all(status: "ok")
    run_line("remote a b")
    assert_response :forbidden
    assert_match(/usage: remote/, response.parsed_body["reason"])
    run_line("remote ../x")
    assert_response :forbidden
    assert_match(/not a node ID/, response.parsed_body["reason"])
  end

  test "in a machine: its table, the permission, exit" do
    users(:user).update!(rshell_access: "read")
    inside
    body = run_line("ls -l", remote: "fmruby-aaaaaa")
    assert_response :created
    row = TerminalCommand.find(body["id"])
    assert_equal [ "pending", "ls", "read", "fmruby-aaaaaa", "exec_read" ],
                 [ row.status, row.command, row.effect, row.remote, row.method_name ]
    assert_equal({ "node" => "fmruby-aaaaaa", "cwd" => "/home" }, body["remote"])
    row.update!(status: "ok")

    body = run_line("rm a.txt", remote: "fmruby-aaaaaa")
    assert_response :forbidden
    assert_match(/rm: changes the machine; you may only read/, body["reason"])
    assert_equal [ "denied", "write", "fmruby-aaaaaa" ], TerminalCommand.find(body["id"]).then { [ _1.status, _1.effect, _1.remote ] }
    users(:user).update!(rshell_access: "write")
    body = run_line("rm a.txt", remote: "fmruby-aaaaaa")
    assert_response :created
    assert_equal [ "write", "exec_write", false ], TerminalCommand.find(body["id"]).then { [ _1.effect, _1.method_name, _1.confirmed ] }
    TerminalCommand.update_all(status: "ok")
    body = run_line("rm /etc/x", remote: "fmruby-aaaaaa", confirmed: true)
    assert TerminalCommand.find(body["id"]).confirmed, "y to the question"
    TerminalCommand.update_all(status: "ok")

    body = run_line("node list", remote: "fmruby-aaaaaa")
    assert_response :forbidden
    assert_match(/node: not a command of this remote shell/, body["reason"])
    run_line("remote fmruby-bbbbbb", remote: "fmruby-aaaaaa")
    assert_match(/you are in fmruby-aaaaaa \(exit leaves it first\)/, response.parsed_body["reason"])
    run_line("get a.txt", remote: "fmruby-aaaaaa")
    assert_match(/not in this version of the console/, response.parsed_body["reason"])

    users(:user).update!(rshell_access: "none")
    body = run_line("exit", remote: "fmruby-aaaaaa")
    assert_response :created
    assert_equal [ "exit", "close", "close" ], TerminalCommand.find(body["id"]).then { [ _1.command, _1.effect, _1.method_name ] }
  end

  test "where the page believes it is: a session that ended, or one it did not know of" do
    users(:user).update!(rshell_access: "write")
    body = run_line("ls", remote: "fmruby-aaaaaa")
    assert_response :conflict
    assert_match(/the remote shell on fmruby-aaaaaa has ended/, body["error"])
    assert_nil body["remote"]
    inside(cwd: "/tmp")
    body = run_line("node list")
    assert_response :conflict
    assert_equal({ "node" => "fmruby-aaaaaa", "cwd" => "/tmp" }, body["remote"])
    assert_equal 0, TerminalCommand.count, "nothing written"
  end

  test "Tab in a machine asks the machine (the row says which)" do
    users(:user).update!(rshell_access: "read")
    inside
    post complete_terminal_path, params: { page: PAGE, line: "cat my\\ f" }, as: :json
    assert_response :created
    assert_equal [ "complete", "fmruby-aaaaaa" ], TerminalCommand.find(response.parsed_body["id"]).then { [ _1.kind, _1.remote ] }
    users(:user).update!(rshell_access: "none")
    post complete_terminal_path, params: { page: PAGE, line: "cat " }, as: :json
    assert_equal [], response.parsed_body["candidates"]
  end

  test "the call log says the remote shell's lines and their machine" do
    users(:user).update!(rshell_access: "read")
    inside
    run_line("cat notes.txt", remote: "fmruby-aaaaaa")
    TerminalCommand.last.update!(status: "ok", exit_code: 0, output: "hello")
    get calls_path
    assert_response :success
    assert_select "#terminal td", text: /remote shell\s+fmruby-aaaaaa\s+cat notes.txt/
  end
end
