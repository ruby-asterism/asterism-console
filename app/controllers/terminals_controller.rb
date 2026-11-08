# The Terminal (docs/terminal.md): the asterism command line's commands
# typed on a page, run by the bridge on the console's connection.
#
#   GET  /terminal                    the page
#   POST /terminal/lease              the page is open (every 10 s; page token)
#   POST /terminal/release            the page closes (sendBeacon on pagehide)
#   POST /terminal/commands           a line typed (Enter)
#   POST /terminal/commands/:id/stop  Ctrl-C
#   POST /terminal/complete           Tab
#
# The page's token is its user's: another user's token is refused, and the
# output goes on a stream only that user may take (ConsoleChannel).
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
    line = Terminal::Line.check(params[:line])
    return render(json: { "status" => "empty" }) if line.empty?
    expire_stale(page)
    if line.ok? && TerminalCommand.runs.active.exists?(page: page)
      return render(json: { "error" => "a command is running on this page (Ctrl-C stops it)" }, status: :conflict)
    end
    if line.ok? && TerminalCommand.runs.active.where(user: current_user).count >= TerminalCommand::PER_USER
      return render(json: { "error" => "#{TerminalCommand::PER_USER} commands of yours are running already " \
                                        "(on other Terminal pages); stop one first" }, status: :too_many_requests)
    end
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

  def complete
    page = params[:page].to_s
    return head(:forbidden) unless TerminalSession.owned?(page, current_user)
    text = params[:line].to_s
    return render(json: { "candidates" => [] }) if text.bytesize > Terminal::Line::MAX_BYTES ||
                                                   text.match?(/[\x00-\x1f\x7f]/)
    cmd = TerminalCommand.create!(user: current_user, page: page, kind: "complete", line: text, cols: cols)
    render json: { "id" => cmd.id }, status: :created
  end

  private

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
