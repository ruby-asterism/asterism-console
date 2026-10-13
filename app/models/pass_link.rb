# The link a pass is shown with: the page configured to join the network
# from a browser (ASTERISM_BROWSER_PAGE, BrowserPage), told which router to
# use and the pass in the fragment (G1). A fragment is never sent to the
# server that serves the page, so its access log never sees the pass. The
# page takes it out of the address bar at once and puts it on its
# WebSocket URL as ?pass=, which the router's door checks. From the
# environment:
#
#   ASTERISM_PASS_ROUTER   the locator the page uses, e.g. ws/router.example.org:7443
#                          (the page picks wss:// itself when served over https)
#   ASTERISM_BROWSER_PAGE  the page, as a URL template (BrowserPage, G1.5); the
#                          link fills in the router and the pass and leaves the
#                          node and the app empty (the page picks its own node).
#                          Not set: no link (the pass is shown alone).
#
# (Before O1, ASTERISM_STUDIO_URL named one particular page for this; it is
# no longer read: put the page in ASTERISM_BROWSER_PAGE.)
module PassLink
  module_function

  def router(env = ENV)
    env["ASTERISM_PASS_ROUTER"].presence
  end

  def url(token, env = ENV)
    return nil unless BrowserPage.enabled?(env)
    BrowserPage.url(pass: token, node: "", app: "", router: router(env), env: env)
  end
end
