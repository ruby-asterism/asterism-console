require "test_helper"

# Admin > Studio apps (0.3.12): an admin adds, changes and removes the apps
# "Launch Web Studio" may start; Make a pass offers them and open takes
# nothing else.
class Admin::BrowserAppsControllerTest < ActionDispatch::IntegrationTest
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

  test "an admin adds, changes and removes an app" do
    sign_in_as(users(:admin))
    get admin_browser_apps_path
    assert_response :success
    assert_select "title", "Studio apps - Asterism Console"
    assert_select ".nav-group.admin a.current[href=?]", admin_browser_apps_path, "Studio apps"
    assert_select "td code", "/app/test/othello.app.rb"
    assert_difference("BrowserApp.count", 1) do
      post admin_browser_apps_path, params: { browser_app: { label: "Mahjong", path: "/app/game/mahjong/mahjong.app.rb", position: "" } }
    end
    assert_redirected_to admin_browser_apps_path
    app = BrowserApp.find_by!(path: "/app/game/mahjong/mahjong.app.rb")
    assert_equal [ "Mahjong", nil ], [ app.label, app.position ]
    assert_no_difference("BrowserApp.count") do
      post admin_browser_apps_path, params: { browser_app: { path: "/app/test/othello.app.rb" } }
    end
    assert_response :unprocessable_content, "each path once"
    assert_no_difference("BrowserApp.count") { post admin_browser_apps_path, params: { browser_app: { path: "/app/x y" } } }
    assert_response :unprocessable_content
    get edit_admin_browser_app_path(app)
    assert_select "input[name='browser_app[path]'][value=?]", app.path
    patch admin_browser_app_path(app), params: { browser_app: { label: "", path: "/app/game/board/board.app.rb", position: "1" } }
    assert_redirected_to admin_browser_apps_path
    assert_equal [ nil, "/app/game/board/board.app.rb", 1 ], app.reload.then { [ _1.label, _1.path, _1.position ] }
    patch admin_browser_app_path(app), params: { browser_app: { path: "" } }
    assert_response :unprocessable_content
    assert_difference("BrowserApp.count", -1) { delete admin_browser_app_path(app) }
    assert_redirected_to admin_browser_apps_path
  end

  test "users cannot see or change them; nor admins from outside CONSOLE_ADMIN_NETS" do
    sign_in_as(users(:user))
    get admin_browser_apps_path
    assert_redirected_to root_path
    assert_no_difference("BrowserApp.count") { post admin_browser_apps_path, params: { browser_app: { path: "/app/x.rb" } } }
    assert_no_difference("BrowserApp.count") { delete admin_browser_app_path(browser_apps(:othello)) }
    sign_out
    with_env("CONSOLE_ADMIN_NETS" => "192.0.2.0/24") do
      sign_in_as(users(:admin))
      get admin_browser_apps_path, headers: { "X-Forwarded-For" => "203.0.113.5" }
      assert_response :forbidden
      get admin_browser_apps_path, headers: { "X-Forwarded-For" => "192.0.2.44" }
      assert_response :success
    end
  end

  test "Make a pass offers the list, and open takes only what is on it" do
    with_env("ASTERISM_BROWSER_PAGE" => PAGE, "ASTERISM_PASS_ROUTER" => "ws/router.example.org:7443") do
      sign_in_as(users(:user))
      board = "/app/game/board/board.app.rb"
      post open_browser_passes_path, params: { app: board }
      assert_response :unprocessable_content, "not on the list"
      BrowserApp.create!(label: "Board", path: board, position: 1)
      get browser_passes_path
      assert_select "select[name=app] option", 3
      assert_select "select[name=app] option:nth-child(1)[value='']", "Nothing (the page's own start)"
      assert_select "select[name=app] option:nth-child(2)[value=?]", board, "Board (#{board})"
      assert_select "select[name=app] option:nth-child(3)[value='/app/test/othello.app.rb']", "Othello (/app/test/othello.app.rb)"
      post open_browser_passes_path, params: { app: board }
      assert_response :success
      assert_includes response.body, "app=#{ERB::Util.url_encode(board)}"
      browser_apps(:othello).destroy!
      post open_browser_passes_path, params: { app: "/app/test/othello.app.rb" }
      assert_response :unprocessable_content, "removed from the list"
      post open_browser_passes_path, params: { app: "" }
      assert_response :success, "nothing is always there"
    end
  end
end
