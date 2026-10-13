require "test_helper"

# "Open the browser build" (G1.5): only with a page configured; a fresh
# pass, a node ID tied to the user, an app the roles name; the URL reaches
# the new tab in the body (never a redirect or the log).
class BrowserPageOpenTest < ActionDispatch::IntegrationTest
  PAGE = "https://play.example.org/?zenoh={router}#zenoh_pass={pass}&zenoh_node={node}&app={app}".freeze
  setup do
    RateLimits::STORE.clear
  end

  def with_env(vars)
    old = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { ENV[_1] = _2 }
    yield
  ensure
    old.each { ENV[_1] = _2 }
  end

  def page_url
    css_select("meta[http-equiv=refresh]").first["content"].delete_prefix("0;url=")
  end

  test "no page configured: no button, and open is not there" do
    with_env("ASTERISM_BROWSER_PAGE" => nil) do
      sign_in_as(users(:user))
      get browser_passes_path
      assert_select "input[type=submit][value='Open the browser build']", 0
      post open_browser_passes_path, params: { app: "" }
      assert_response :not_found
    end
  end

  test "a template without the pass in its fragment, or without the node, is not used" do
    with_env("ASTERISM_BROWSER_PAGE" => "https://play.example.org/?pass={pass}&zenoh_node={node}") do
      refute BrowserPage.enabled?
    end
    with_env("ASTERISM_BROWSER_PAGE" => "https://play.example.org/?zenoh={router}#zenoh_pass={pass}") do
      refute BrowserPage.enabled?, "every link names the node"
    end
  end

  test "open: a pass for the user's node and the app, in the fragment, once" do
    with_env("ASTERISM_BROWSER_PAGE" => PAGE, "ASTERISM_PASS_ROUTER" => "ws/router.example.org:7443") do
      sign_in_as(users(:user))
      get browser_passes_path
      assert_select "form[target=_blank] select[name=app] option[value='/app/test/othello.app.rb']"
      assert_select "code", "wasm-pat"
      io = StringIO.new
      old = Rails.logger
      Rails.logger = ActionController::Base.logger = ActiveSupport::TaggedLogging.logger(io)
      post open_browser_passes_path, params: { app: "/app/test/othello.app.rb" }
      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      url = page_url
      pass = BrowserPass.order(:id).last
      token = url[/zenoh_pass=([^&]+)/, 1]
      assert_equal BrowserPass.digest(token), pass.token_digest
      assert_equal "https://play.example.org/?zenoh=ws%2Frouter.example.org%3A7443#zenoh_pass=#{token}" \
                   "&zenoh_node=wasm-pat&app=%2Fapp%2Ftest%2Fothello.app.rb", url
      assert_equal [ "wasm-pat", "/app/test/othello.app.rb" ], [ pass.node, pass.app ]
      refute_includes io.string, token
      refute_includes io.string, "user@example.com", "the log names the user by id and handle"
      post open_browser_passes_path, params: { app: "" }
      assert_includes page_url, "zenoh_node=wasm-pat_2", "the first page has not connected yet: the next name"
      post open_browser_passes_path, params: { app: "/etc/passwd" }
      assert_response :unprocessable_content, "only the apps the roles name"
      sign_out
      get check_browser_passes_path, headers: { "X-Asterism-Pass" => token }
      assert_response :no_content
      get check_browser_passes_path, headers: { "X-Asterism-Pass" => token }
      assert_response :unauthorized, "once, for a page that names no key"
    ensure
      Rails.logger = ActionController::Base.logger = old if old
    end
  end

  test "without a handle: no button, a way to choose one, and open refuses" do
    with_env("ASTERISM_BROWSER_PAGE" => PAGE, "ASTERISM_PASS_ROUTER" => "ws/router.example.org:7443") do
      sign_in_as(users(:admin))
      get browser_passes_path
      assert_select "input[type=submit][value='Open the browser build']", 0
      assert_select "button, input[type=submit]", { text: "Make a pass", count: 0 }
      assert_select "a[href=?]", account_path(anchor: "handle"), "Choose your handle"
      post open_browser_passes_path, params: { app: "" }
      assert_redirected_to account_path(anchor: "handle")
      post browser_passes_path
      assert_redirected_to account_path(anchor: "handle"), "no pass at all without a handle"
      assert_equal 0, BrowserPass.count
      patch handle_account_path, params: { handle: "pat" }
      assert_redirected_to account_path(anchor: "handle")
      assert_nil users(:admin).reload.handle, "taken by another user"
      patch handle_account_path, params: { handle: "Ada" }
      assert_equal "ada", users(:admin).reload.handle
      post open_browser_passes_path, params: { app: "" }
      assert_response :success
      assert_includes page_url, "zenoh_node=wasm-ada&"
      refute_includes page_url, "admin"
    end
  end

  test "the plain pass link has the same form: the pass and the user's node, no app" do
    with_env("ASTERISM_BROWSER_PAGE" => PAGE, "ASTERISM_PASS_ROUTER" => "ws/router.example.org:7443") do
      assert_equal "https://play.example.org/?zenoh=ws%2Frouter.example.org%3A7443#zenoh_pass=abc&zenoh_node=wasm-pat&app=",
                   PassLink.url("abc", node: "wasm-pat")
      assert_raises(ArgumentError) { PassLink.url("abc", node: "") }
      sign_in_as(users(:user))
      get browser_passes_path
      assert_select "code", "wasm-pat"
      post browser_passes_path
      assert_response :created
      link = css_select("dd a.wrap").first["href"]
      assert_includes link, "&zenoh_node=wasm-pat&app="
      assert_select "code.node", "wasm-pat"
      assert_equal "wasm-pat", BrowserPass.sole.node
      assert_select "code", "wasm-pat_2", "the pass waits to be used: the next one gets the next name"
      post open_browser_passes_path, params: { app: "" }
      assert_includes page_url, "zenoh_node=wasm-pat_2&"
    end
  end

  test "no page: the pass is shown with its node, without a link (ASTERISM_STUDIO_URL is no longer read)" do
    with_env("ASTERISM_BROWSER_PAGE" => nil, "ASTERISM_STUDIO_URL" => "https://play.example.org/") do
      assert_nil PassLink.url("abc", node: "wasm-pat")
      sign_in_as(users(:user))
      post browser_passes_path
      assert_response :created
      assert_select "dt", { text: "Link", count: 0 }
      assert_select "dd code.wrap"
      assert_select "code.node", "wasm-pat"
      assert_select "p.hint", /both the pass and the node/
    end
  end
end
