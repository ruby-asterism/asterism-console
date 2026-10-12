# The link a pass is shown with: the browser build, told which router to
# use (?zenoh=, as today) and the pass (?zenoh_pass=, which the browser
# build does not read yet: a proposal, see docs/g0_w4.md; it would put the
# pass on its WebSocket URL as ?pass=, which the router's door checks). From the environment:
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
    q = { "zenoh" => router(env), "zenoh_pass" => token }.compact
    sep = studio(env).include?("?") ? "&" : "?"
    studio(env) + sep + URI.encode_www_form(q)
  end
end
