# "Open the browser build" (G1.5): a page that can join the network from a
# browser (for example a build of an Asterism app for the web), opened in a
# new tab with a fresh pass, a node ID tied to the signed-in user and the
# app to start. The page is an integration, configured by a URL template;
# without one the console offers no button (passes still work, PassLink).
#
#   ASTERISM_BROWSER_PAGE  the page's URL with placeholders, each filled in
#                          URL-encoded:
#                            {router}  ASTERISM_PASS_ROUTER (the wss:// door's locator)
#                            {pass}    the pass (one connection); MUST be in the fragment
#                            {node}    the node ID the page joins as (Relay::BrowserNode)
#                            {app}     what the page starts ("" for nothing)
#                          e.g. https://studio.example.org/?zenoh={router}#zenoh_pass={pass}&zenoh_node={node}&app={app}
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

  # http(s), and {pass} only after the #.
  def usable?(t)
    uri_part, fragment = t.split("#", 2)
    t.match?(%r{\Ahttps?://[^/\s]+}) && fragment.to_s.include?("{pass}") && !uri_part.include?("{pass}")
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

  # What the page can start: nothing, or the apps the roles name.
  # [[label, value]]
  def apps
    [ [ "Nothing (the page's own start)", "" ] ] +
      RelayRole.where.not(browser_app: [ nil, "" ]).order(:name).map { [ "#{_1.browser_app} (#{_1.name})", _1.browser_app ] }
               .uniq { _1[1] }
  end
end
