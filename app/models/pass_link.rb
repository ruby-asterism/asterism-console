# The link a pass is shown with: the browser build, told which router to
# use (?zenoh=) and the pass in the fragment (#zenoh_pass=, G1). A fragment
# is never sent to the server that serves the page, so its access log (a
# github.io-style host) never sees the pass. The page takes it out of the
# address bar at once and puts it on its WebSocket URL as ?pass=, which the
# router's door checks. From the environment:
#
#   ASTERISM_STUDIO_URL    https://family-mruby.github.io/studio/  (the browser build)
#   ASTERISM_PASS_ROUTER   the locator the page uses, e.g. ws/router.example.org:7443
#                          (the page picks wss:// itself when served over https)
module PassLink
  module_function

  def studio(env = ENV)
    env["ASTERISM_STUDIO_URL"].presence || "https://family-mruby.github.io/studio/"
  end

  def router(env = ENV)
    env["ASTERISM_PASS_ROUTER"].presence
  end

  def url(token, env = ENV)
    base = studio(env)
    if (r = router(env))
      base += (base.include?("?") ? "&" : "?") + URI.encode_www_form("zenoh" => r)
    end
    base + "#" + URI.encode_www_form("zenoh_pass" => token)
  end
end
