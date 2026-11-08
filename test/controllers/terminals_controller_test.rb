require "test_helper"

# The Terminal's page and requests: a page token per user, what a line
# becomes (pending, or denied with its reason and kept), one command at a
# time per page, the per-user limit, Ctrl-C, Tab.
class TerminalsControllerTest < ActionDispatch::IntegrationTest
  PAGE = "page-aaaaaaaaaaaaaaaa"

  setup do
    sign_in_as(users(:user))
    post lease_terminal_path, params: { page: PAGE }, as: :json
    assert_response :success
  end

  def run_line(line, page: PAGE)
    post commands_terminal_path, params: { page: page, line: line, cols: 100 }, as: :json
    response.parsed_body
  end

  test "the page, with the xterm styles allowed inline and the scripts still under the nonce" do
    get terminal_path
    assert_response :success
    assert_select "[data-controller=terminal][data-terminal-available-value=true]"
    assert_select "meta[name=turbo-visit-control][content=reload]"
    csp = response.headers["Content-Security-Policy"]
    assert_match(/style-src 'self' 'unsafe-inline'(;|$)/, csp)
    assert_match(/script-src 'self' 'nonce-/, csp)
    get calls_path
    assert_match(/style-src 'self' [^;]*'nonce-/, response.headers["Content-Security-Policy"], "other pages keep it")
  end

  test "a page token is its user's" do
    sign_in_as(users(:admin))
    post lease_terminal_path, params: { page: PAGE }, as: :json
    assert_response :forbidden
    run_line("node list")
    assert_response :forbidden
    post complete_terminal_path, params: { page: PAGE, line: "no" }, as: :json
    assert_response :forbidden
    post lease_terminal_path, params: { page: "short" }, as: :json
    assert_response :forbidden
  end

  test "a line that reads waits for the bridge; one at a time on a page" do
    body = run_line("node list")
    assert_response :created
    cmd = TerminalCommand.find(body["id"])
    assert_equal [ "pending", "node list", "read", %w[node list], 100, users(:user) ],
                 [ cmd.status, cmd.command, cmd.effect, cmd.argv_value, cmd.cols, cmd.user ]
    run_line("tree")
    assert_response :conflict
    assert_match(/a command is running/, response.parsed_body["error"])
  end

  test "refused lines are kept with the reason" do
    body = run_line("ls -la /")
    assert_response :forbidden
    assert_equal "denied", body["status"]
    assert_match(/"ls" is not an asterism command/, body["reason"])
    row = TerminalCommand.find(body["id"])
    assert_equal [ "denied", "ls -la /", users(:user) ], [ row.status, row.line, row.user ]
    assert row.finished_at
    run_line("call fmruby-aaaaaa/demo/screen say hi")
    assert_response :forbidden
    assert_match(/no call permission allows fmruby-aaaaaa\/demo\/screen say/, response.parsed_body["reason"])
    assert_equal "call", response.parsed_body["effect"]
    run_line("node list --router tcp/192.0.2.2:7447")
    assert_response :forbidden
    run_line("mcp")
    assert_response :forbidden
    assert_equal 4, TerminalCommand.runs.where(status: "denied").count
    assert_equal({ "status" => "empty" }, run_line("   "))
  end

  test "a call the permissions allow" do
    CallPermission.create!(node: "fmruby-*", app: "demo", object: "screen", method_name: "say")
    body = run_line("call fmruby-aaaaaa/demo/screen say hi")
    assert_response :created
    assert_equal [ "pending", "call", "fmruby-aaaaaa/demo/screen", "say" ], body.values_at("status", "effect", "path", "method")
  end

  test "at most PER_USER at once, across the user's pages" do
    TerminalCommand::PER_USER.times do |i|
      TerminalCommand.create!(user: users(:user), page: "other-page-#{i}-aaaaaaaaaa", line: "watch", status: "running")
    end
    run_line("node list")
    assert_response :too_many_requests
    run_line("ls") # refused anyway: kept as denied
    assert_response :forbidden
  end

  test "Ctrl-C: a pending one never runs, a running one is stopped by the bridge" do
    id = run_line("watch")["id"]
    post stop_terminal_path(id: id), as: :json
    assert_equal "stopped", TerminalCommand.find(id).status
    cmd = TerminalCommand.create!(user: users(:user), page: PAGE, line: "watch", status: "running")
    GraphState.current.update!(bridge_seen_at: Time.current)
    post stop_terminal_path(id: cmd.id), as: :json
    assert_equal "stopping", cmd.reload.status
    sign_in_as(users(:admin))
    post stop_terminal_path(id: cmd.id), as: :json
    assert_response :not_found, "only its user"
  end

  test "rows no bridge will finish do not hold the page" do
    TerminalCommand.create!(user: users(:user), page: PAGE, line: "watch", status: "pending", created_at: 1.minute.ago)
    run_line("node list")
    assert_response :created
    TerminalCommand.where(page: PAGE, status: "pending").update_all(status: "running")
    GraphState.current.update!(bridge_seen_at: nil)
    run_line("node list")
    assert_response :created, "no bridge: what it ran is over"
    assert_equal [ "expired", "stopped", "pending" ], TerminalCommand.where(page: PAGE).order(:id).pluck(:status)
  end

  test "Tab asks the bridge; release ends the page" do
    post complete_terminal_path, params: { page: PAGE, line: "node l", cols: 90 }, as: :json
    assert_response :created
    row = TerminalCommand.find(response.parsed_body["id"])
    assert_equal [ "complete", "node l", "pending" ], [ row.kind, row.line, row.status ]
    post release_terminal_path, params: { page: PAGE }
    assert_response :no_content
    refute TerminalSession.exists?(page: PAGE)
    run_line("node list")
    assert_response :forbidden
  end

  test "the call log shows the Terminal's commands: one's own, or everyone's to an admin" do
    run_line("node list")
    run_line("ls")
    TerminalCommand.create!(user: users(:admin), page: "admin-page-aaaaaaaaaaaa", line: "tree", status: "ok",
                            output: "calcnode")
    get calls_path
    assert_select "#terminal tbody tr", 2
    assert_select "#terminal", /ls/
    sign_in_as(users(:admin))
    get calls_path
    assert_select "#terminal tbody tr", 3
    assert_select "#terminal", /calcnode/
  end
end
