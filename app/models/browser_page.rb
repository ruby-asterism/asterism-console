# "Launch Web Studio" (G1.5; "Open the browser build" before 0.3.5): a page that can join the network from a
# browser (for example a build of an Asterism app for the web), opened in a
# new tab with a fresh pass, a node ID tied to the signed-in user and the
# app to start. The page is an integration, configured by a URL template;
# without one the console offers no button (passes are shown alone, with
# the node they are for: PassLink).
#
#   ASTERISM_BROWSER_PAGE  the page's URL with placeholders, each filled in
#                          URL-encoded:
#                            {router}  ASTERISM_PASS_ROUTER (the wss:// door's locator)
#                            {pass}    the pass (one connection); MUST be in the fragment
#                            {node}    the node ID the page joins as (Relay::BrowserNode); MUST be there
#                            {app}     what the page starts ("" for nothing)
#                          e.g. https://play.example.org/?zenoh={router}#zenoh_pass={pass}&zenoh_node={node}&app={app}
#
# Every link the console gives a browser names the node: on a network the
# console runs, the console decides who a page is (from the user's handle),
# and the page refuses a link with a pass but no node (2026-10-14). So a
# template without {node} is not used either.
#
# A fragment is never sent to the server that serves the page, so its log
# never sees the pass (nor the node and app, when they are there too). The
# console hands the URL to the new tab in the body of a page that is not
# kept (no redirect: Rails would log the Location).
module BrowserPage
  PLACEHOLDERS = %w[router pass node app].freeze

  module_function

  def template(env = ENV)
    t = env["ASTERISM_BROWSER_PAGE"].presence
    t if t && usable?(t)
  end

  def enabled?(env = ENV)
    template(env).present?
  end

  # http(s), {pass} only after the #, and {node}.
  def usable?(t)
    uri_part, fragment = t.split("#", 2)
    t.match?(%r{\Ahttps?://[^/\s]+}) && fragment.to_s.include?("{pass}") && !uri_part.include?("{pass}") &&
      t.include?("{node}")
  end

  def url(pass:, node:, app: "", router: PassLink.router, env: ENV)
    t = template(env) or raise ArgumentError, "ASTERISM_BROWSER_PAGE is not set (or has no {pass} in its fragment)"
    values = { "router" => router.to_s, "pass" => pass.to_s, "node" => node.to_s, "app" => app.to_s }
    t.gsub(/\{(#{PLACEHOLDERS.join('|')})\}/) { ERB::Util.url_encode(values.fetch(Regexp.last_match(1))) }
  end

  # The page's origin (scheme, host, port), for the pages that show it.
  def origin(env = ENV)
    t = template(env) or return nil
    t[%r{\Ahttps?://[^/?#]+}]
  end

  # What the page can start: nothing, or an app of the list (BrowserApp,
  # Admin > Studio apps; the roles named them before 0.3.12).
  # [[label, value]]
  def apps
    [ [ "Nothing (the page's own start)", "" ] ] + BrowserApp.in_order.map(&:option)
  end
end
