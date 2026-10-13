# The link a pass is shown with: the page configured to join the network
# from a browser (ASTERISM_BROWSER_PAGE, BrowserPage), told which router to
# use, and in the fragment the pass and the node ID the page joins as (G1,
# 2026-10-14). A fragment is never sent to the server that serves the page,
# so its access log never sees the pass. The page takes it out of the
# address bar at once and puts it on its WebSocket URL as ?pass=, which the
# router's door checks. From the environment:
#
#   ASTERISM_PASS_ROUTER   the locator the page uses, e.g. ws/router.example.org:7443
#                          (the page picks wss:// itself when served over https)
#   ASTERISM_BROWSER_PAGE  the page, as a URL template (BrowserPage, G1.5); the
#                          link fills in the router, the pass and the node (the
#                          user's, Relay::BrowserNode) and leaves the app empty.
#                          Not set: no link (the pass and the node are shown alone).
#
# A link always names the node: the browser build refuses one with a pass
# and no node (it would otherwise join as an ID of its own, and the same
# person would show up under another name depending on the link).
#
# (Before O1, ASTERISM_STUDIO_URL named one particular page for this; it is
# no longer read: put the page in ASTERISM_BROWSER_PAGE.)
module PassLink
  module_function

  def router(env = ENV)
    env["ASTERISM_PASS_ROUTER"].presence
  end

  def url(token, node:, env: ENV)
    raise ArgumentError, "a pass link names the node" if node.blank?
    return nil unless BrowserPage.enabled?(env)
    BrowserPage.url(pass: token, node: node, app: "", router: router(env), env: env)
  end
end
