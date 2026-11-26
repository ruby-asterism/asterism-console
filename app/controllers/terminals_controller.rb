# The Terminal (docs/terminal.md): the asterism command line's commands
# typed on a page, run by the bridge on the console's connection.
#
#   GET  /terminal                    the page
#   POST /terminal/lease              the page is open (every 10 s; page token)
#   POST /terminal/release            the page closes (sendBeacon on pagehide)
#   POST /terminal/commands           a line typed (Enter)
#   POST /terminal/commands/:id/stop  Ctrl-C
#   POST /terminal/complete           Tab
#   POST /terminal/uploads            the files chosen for put (multipart)
#   GET  /terminal/files/:token       the file a get brought (its user, once)
#
# The page's token is its user's: another user's token is refused, and the
# output goes on a stream only that user may take (ConsoleChannel).
#
# The remote shell (docs/terminal.md): remote <node> asks the bridge to go
# into a machine, and while the page's TerminalSession says it is in one
# (remote, the bridge's copy), a line is the remote shell's
# (Terminal::Remote: the machine's table and the user's rshell_access), not
# the asterism command line's. The page says where it believes it is
# (remote); when that is not so (the bridge restarted, the session ended),
# the line is refused with where it is now.
class TerminalsController < ApplicationController
  # xterm.js puts <style> elements of its own into the page (the cells'
  # sizes and colours) and cannot give them a nonce: on this page styles
  # may be inline. Scripts keep the nonce, as everywhere.
  content_security_policy only: :show do |policy|
    policy.style_src :self, :unsafe_inline
  end
  before_action only: :show do
    request.content_security_policy_nonce_directives = %w[script-src]
  end

  def show
    @available = Terminal::Line.available?
  end

  def lease
    row = TerminalSession.renew(page: params[:page], user: current_user)
    return head(:forbidden) unless row
    render json: { "page" => row.page, "expires_at" => row.expires_at }
  end

  def release
    TerminalSession.release(page: params[:page], user: current_user)
    head :no_content
  end

  def run
    page = params[:page].to_s
    return render(json: { "error" => "this page is not open (reload it)" }, status: :forbidden) unless
      TerminalSession.owned?(page, current_user)
    session = TerminalSession.live.find_by(page: page, user: current_user)
    remote = session&.remote_value
    if params[:remote].to_s != remote&.dig("node").to_s
      why = params[:remote].present? ? "the remote shell on #{params[:remote]} has ended" : "this page is in #{remote['node']}"
      return render(json: { "error" => why, "remote" => remote_state(remote) }, status: :conflict)
    end
    words = Terminal::Remote.split(params[:line].to_s)[0]
    return run_remote(page, remote) if remote
    return enter_remote(page, words) if words.first == "remote"
    line = Terminal::Line.check(params[:line])
    return render(json: { "status" => "empty" }) if line.empty?
    return unless may_start(page, line.ok?)
    cmd = TerminalCommand.create!(
      user: current_user, page: page, kind: "run", line: params[:line].to_s, argv: JSON.generate(line.words),
      command: line.command, effect: line.effect, path: line.path, method_name: line.method_name, cols: cols,
      status: line.ok? ? "pending" : "denied", reason: line.reason, finished_at: (Time.current unless line.ok?)
    )
    render json: cmd.as_payload, status: line.ok? ? :created : :forbidden
  end

  def stop
    cmd = TerminalCommand.runs.find_by(id: params[:id], user: current_user)
    return head(:not_found) unless cmd
    # Pending: it never runs. Running: the bridge ends it (CLI stop:).
    TerminalCommand.where(id: cmd.id, status: "pending")
                   .update_all(status: "stopped", reason: "stopped before it started (Ctrl-C)", finished_at: Time.current,
                               updated_at: Time.current)
    TerminalCommand.where(id: cmd.id, status: "running").update_all(status: "stopping", updated_at: Time.current)
    expire_stale(cmd.page)
    render json: cmd.reload.as_payload
  end

  # put's files (docs/terminal.md, "Files: get and put"): the page uploads
  # what was chosen (or dropped) and then sends the line with the token.
  def upload
    page = params[:page].to_s
    return render(json: { "error" => "this page is not open (reload it)" }, status: :forbidden) unless
      TerminalSession.owned?(page, current_user)
    unless current_user.rshell_access == "write"
      return render(json: { "error" => "put: changes the machine; you may only read with the remote shell (an admin " \
                                       "chooses, under Users)" }, status: :forbidden)
    end
    unless TerminalSession.live.find_by(page: page, user: current_user)&.remote_node
      return render(json: { "error" => "put: this page is in no machine (remote <node> first)" }, status: :conflict)
    end
    TerminalFiles.sweep
    token = TerminalFiles.new_put(user_id: current_user.id, page: page, files: Array(params[:files]))
    render json: { "upload" => token }, status: :created
  rescue ArgumentError => e
    render json: { "error" => "put: #{e.message}" }, status: :unprocessable_content
  end

  # The file of a get, for the user who asked, once (then it is gone).
  def download
    f = TerminalFiles.take_get(params[:token], current_user)
    return head(:not_found) unless f
    send_data f["data"], filename: f["name"], type: "application/octet-stream", disposition: "attachment"
  end

  def complete
    page = params[:page].to_s
    return head(:forbidden) unless TerminalSession.owned?(page, current_user)
    text = params[:line].to_s
    return render(json: { "candidates" => [] }) if text.bytesize > Terminal::Line::MAX_BYTES ||
                                                   text.match?(/[\x00-\x1f\x7f]/)
    remote = TerminalSession.live.find_by(page: page, user: current_user)&.remote_node
    return render(json: { "candidates" => [] }) if remote && !current_user.rshell?
    cmd = TerminalCommand.create!(user: current_user, page: page, kind: "complete", line: text, cols: cols, remote: remote)
    render json: { "id" => cmd.id }, status: :created
  end

  private

  # One command at a time per page, PER_USER per user (ok: the line is
  # taken; a refused one is written as it is). Renders the refusal and
  # answers false.
  def may_start(page, ok)
    expire_stale(page)
    if ok && TerminalCommand.runs.active.exists?(page: page)
      render(json: { "error" => "a command is running on this page (Ctrl-C stops it)" }, status: :conflict)
      return false
    end
    if ok && TerminalCommand.runs.active.where(user: current_user).count >= TerminalCommand::PER_USER
      render(json: { "error" => "#{TerminalCommand::PER_USER} commands of yours are running already " \
                                "(on other Terminal pages); stop one first" }, status: :too_many_requests)
      return false
    end
    true
  end

  # remote (the list of machines one may go into) or remote <node>.
  def enter_remote(page, words)
    node = words[1]
    reason =
      if !current_user.rshell? then "you may not use the remote shell (an admin chooses who may, under Users)"
      elsif words.size > 2 then "usage: remote [<node>] (the machines that let this console in: remote)"
      elsif node && !Terminal::Remote::NODE.match?(node) then "#{node.inspect} is not a node ID"
      end
    return unless may_start(page, reason.nil?)
    cmd = TerminalCommand.create!(
      user: current_user, page: page, kind: "run", line: params[:line].to_s, argv: JSON.generate(words),
      command: "remote", effect: node ? "open" : "read", remote: node, cols: cols,
      path: (Terminal::Remote.path(node) if node), method_name: ("open" if node),
      status: reason ? "denied" : "pending", reason: reason, finished_at: (Time.current if reason)
    )
    render json: cmd.as_payload, status: reason ? :forbidden : :created
  end

  # A line while the page is in a machine (Rails' check; the bridge checks
  # again before it sends it).
  def run_remote(page, remote)
    node = remote["node"]
    line = Terminal::Remote.check(params[:line], commands: remote["commands"], level: current_user.rshell_access)
    return render(json: { "status" => "empty", "remote" => remote_state(remote) }) if line.empty?
    if line.name == "remote"
      line.reason = "you are in #{node} (exit leaves it first)"
    end
    return unless may_start(page, line.ok?)
    cmd = TerminalCommand.create!(
      user: current_user, page: page, kind: "run", line: params[:line].to_s, argv: JSON.generate(line.words),
      command: line.exit? ? "exit" : line.name, effect: line.exit? ? "close" : line.effect, remote: node, cols: cols,
      path: Terminal::Remote.path(node), method_name: line.method_name,
      confirmed: ActiveModel::Type::Boolean.new.cast(params[:confirmed]) == true,
      files: (JSON.generate("upload" => params[:upload].to_s) if line.kind == "put" && params[:upload].present?),
      status: line.ok? ? "pending" : "denied", reason: line.reason, finished_at: (Time.current unless line.ok?)
    )
    render json: cmd.as_payload.merge("remote" => remote_state(remote)), status: line.ok? ? :created : :forbidden
  end

  # Where the page is, for its prompt.
  def remote_state(remote)
    remote && { "node" => remote["node"], "cwd" => remote["cwd"] }
  end

  # What no bridge will finish: pending rows past their time, and, while no
  # bridge runs, the rows it was running (a bridge that starts again writes
  # those itself).
  def expire_stale(page)
    now = Time.current
    TerminalCommand.runs.where(page: page, status: "pending").where(created_at: ...TerminalCommand::EXPIRE_AFTER.ago)
                   .update_all(status: "expired", reason: "the bridge did not pick it up in time", finished_at: now,
                               updated_at: now)
    return if GraphState.current.bridge_alive?
    TerminalCommand.runs.where(page: page, status: %w[running stopping])
                   .update_all(status: "stopped", reason: "the bridge is not running", finished_at: now, updated_at: now)
  end

  def cols
    params[:cols].to_i.clamp(20, 400)
  end
end
