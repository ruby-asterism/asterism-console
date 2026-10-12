# Passes for the browser build (W4). A signed-in user makes a pass (shown
# once, with a link that opens the browser build on this console's
# router) and may revoke their own; admins see every pass (/admin/passes).
#
# check is the proxy's question (nginx auth_request in front of the
# router's ws/ listener, deploy/vps/nginx): the pass is the "pass" query
# parameter of the WebSocket URL, which nginx hands over as X-Original-URI
# (or the X-Asterism-Pass header); the answer is 204 (open the connection)
# or 401. It needs no session, and the
# public server block of the console does not pass it on (only the
# router's server block reaches it, as a subrequest).
class BrowserPassesController < ApplicationController
  allow_unauthenticated_access only: :check
  skip_forgery_protection only: :check
  rate_limit to: 10, within: 10.minutes, only: :create, by: -> { current_user.id }, store: RateLimits::STORE,
             with: -> { redirect_to browser_passes_path, alert: "Too many passes: wait a few minutes." }
  rate_limit to: 60, within: 1.minute, only: :check, store: RateLimits::STORE, with: -> { head :too_many_requests }
  layout "plain"

  def index
    @passes = current_user.browser_passes.order(id: :desc).limit(20)
  end

  def create
    @new_pass = BrowserPass.issue!(current_user, ip: request.remote_ip)
    Rails.logger.info("pass: #{@new_pass.id} made for #{current_user.email_address} until #{@new_pass.expires_at.utc.iso8601}")
    @link = PassLink.url(@new_pass.token)
    @passes = current_user.browser_passes.order(id: :desc).limit(20)
    response.headers["Cache-Control"] = "no-store"
    render :index, status: :created
  end

  def revoke
    pass = BrowserPass.find(params[:id])
    return head :not_found unless pass.user_id == current_user.id || current_user.admin?
    pass.revoke!(current_user)
    back = current_user.admin? && pass.user_id != current_user.id ? admin_browser_passes_path : browser_passes_path
    redirect_to back, status: :see_other, notice: "Revoked pass #{pass.id}. Connections it opened stay until they close."
  end

  private def pass_from_request
    given = request.headers["X-Asterism-Pass"].to_s
    return given if given.present?
    query = URI.parse(request.headers["X-Original-URI"].to_s).query.to_s
    URI.decode_www_form(query).to_h["pass"].to_s
  rescue URI::InvalidURIError, ArgumentError
    ""
  end

  def check
    token = pass_from_request
    ip = request.remote_ip
    if (pass = BrowserPass.find_live(token))
      pass.used!(ip)
      Rails.logger.info("pass: #{pass.id} (#{pass.user.email_address}) opened a connection from #{ip}")
      head :no_content
    else
      if token.present? && (gone = BrowserPass.find_by(token_digest: BrowserPass.digest(token)))
        BrowserPass.where(id: gone.id).update_all("refused = refused + 1")
        Rails.logger.info("pass: #{gone.id} refused from #{ip} (#{gone.status})")
      else
        Rails.logger.info("pass: refused from #{ip} (#{token.present? ? 'unknown pass' : 'no pass'})")
      end
      head :unauthorized
    end
  end
end
