# Passes for the browser build (W4). A signed-in user makes a pass (shown
# once, with a link that opens the browser build on this console's
# router) and may revoke their own; admins see every pass (/admin/passes).
#
# check is the proxy's question (nginx auth_request in front of the
# router's ws/ listener, deploy/vps/nginx): the pass is the "pass" query
# parameter of the WebSocket URL, which nginx hands over as X-Original-URI
# (Caddy's forward_auth as X-Forwarded-Uri; or the X-Asterism-Pass header); the answer is 204 (open the connection)
# or 401. A pass opens one connection: the first 204 consumes it, and
# later checks with it get 401 (BrowserPass#consume!). It needs no session, and the
# public server block of the console does not pass it on (only the
# router's server block reaches it, as a subrequest).
class BrowserPassesController < ApplicationController
  allow_unauthenticated_access only: :check
  skip_forgery_protection only: :check
  rate_limit to: 10, within: 10.minutes, only: %i[create open], by: -> { current_user.id }, store: RateLimits::STORE,
             with: -> { redirect_to browser_passes_path, alert: "Too many passes: wait a few minutes." }
  rate_limit to: 60, within: 1.minute, only: :check, store: RateLimits::STORE, with: -> { head :too_many_requests }
  layout "plain"

  def index
    @passes = current_user.browser_passes.order(id: :desc).limit(20)
    @next_node = Relay::BrowserNode.pick(current_user) if BrowserPage.enabled? && current_user.handle.present?
  end

  # Opens the browser build in the tab this form targets: a fresh pass, the
  # node ID for this user (Relay::BrowserNode) and the app chosen (one the
  # roles name, or nothing). The URL goes to the tab in the body of a page
  # that is not kept, never in a redirect (the log would show it).
  def open
    return head :not_found unless BrowserPage.enabled?
    app = params[:app].to_s
    return head :unprocessable_content unless BrowserPage.apps.any? { _1[1] == app }
    if current_user.handle.blank?
      return redirect_to account_path, alert: "Choose a handle first: your browser pages join the network as " \
                                              "#{Relay::Settings.browser_node_prefix}<handle>."
    end
    node = Relay::BrowserNode.pick(current_user)
    pass = BrowserPass.issue!(current_user, ip: request.remote_ip, node: node, app: app)
    Rails.logger.info("pass: #{pass.id} made for #{current_user.log_name} to open the browser build as #{node}")
    @url = BrowserPage.url(pass: pass.token, node: node, app: app)
    @node = node
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    render :open, layout: false
  end

  def create
    @new_pass = BrowserPass.issue!(current_user, ip: request.remote_ip)
    Rails.logger.info("pass: #{@new_pass.id} made for #{current_user.log_name} until #{@new_pass.expires_at.utc.iso8601}")
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

  # [pass, page key] from the headers the web server sets (nginx's
  # auth_request: X-Original-URI; Caddy's forward_auth: X-Forwarded-Uri).
  private def pass_from_request
    uri = request.headers["X-Original-URI"].presence || request.headers["X-Forwarded-Uri"]
    query = URI.decode_www_form(URI.parse(uri.to_s).query.to_s).to_h
    [ request.headers["X-Asterism-Pass"].presence || query["pass"].to_s,
      request.headers["X-Asterism-Page"].presence || query["page"] ]
  rescue URI::InvalidURIError, ArgumentError
    [ "", nil ]
  end

  def check
    token, page = pass_from_request
    ip = request.remote_ip
    pass = BrowserPass.find_by_token(token)
    first = pass&.live?
    if pass&.admit!(ip, page)
      pass.reload
      again = first ? "" : " again"
      Rails.logger.info("pass: #{pass.id} (#{pass.user.log_name}) opened a connection#{again} from #{ip}" \
                        "#{pass.open_until ? '' : ' (one connection: the page named no key)'}")
      until_at = pass.open_until || (Time.current + BrowserPass::LIFETIME)
      response.headers["X-Asterism-Until"] = until_at.to_i.to_s
      head :no_content
    else
      if pass
        BrowserPass.where(id: pass.id).update_all("refused = refused + 1")
        why = pass.open? && page ? "another page" : pass.status
        Rails.logger.info("pass: #{pass.id} refused from #{ip} (#{why})")
      else
        Rails.logger.info("pass: refused from #{ip} (#{token.present? ? 'unknown pass' : 'no pass'})")
      end
      head :unauthorized
    end
  end
end
