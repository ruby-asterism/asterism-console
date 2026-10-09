require "test_helper"

class CallPermissionsControllerTest < ActionDispatch::IntegrationTest
  ROW = { call_permission: { node: "fmruby-*", app: "demo", object: "screen", method_name: "say", note: "the demo" } }.freeze

  test "an admin adds and removes a row" do
    sign_in_as(users(:admin))
    get call_permissions_path
    assert_response :success
    assert_select ".hint", /nothing can be called/
    assert_difference("CallPermission.count", 1) { post call_permissions_path, params: ROW }
    assert_redirected_to call_permissions_path
    row = CallPermission.last
    assert_equal [ "fmruby-*/demo/screen", "say", users(:admin) ], [ row.path_pattern, row.method_name, row.created_by ]
    assert_difference("CallPermission.count", -1) { delete call_permission_path(row) }
  end

  test "a bad pattern is not saved" do
    sign_in_as(users(:admin))
    assert_no_difference("CallPermission.count") do
      post call_permissions_path, params: { call_permission: { node: "a/b", app: "*", object: "*", method_name: "x" } }
    end
    assert_response :unprocessable_content
  end

  test "a user sees the rows but cannot change them" do
    row = CallPermission.create!(node: "*", app: "*", object: "*", method_name: "status")
    sign_in_as(users(:user))
    get call_permissions_path
    assert_response :success
    assert_select "td code", "status"
    assert_no_difference("CallPermission.count") { post call_permissions_path, params: ROW }
    assert_redirected_to root_path
    assert_no_difference("CallPermission.count") { delete call_permission_path(row) }
    post call_permissions_path, params: ROW, as: :json
    assert_response :forbidden
  end

  test "the rows that cover an object, as JSON" do
    CallPermission.create!(node: "fmruby-*", app: "demo", object: "screen", method_name: "say")
    CallPermission.create!(node: "cruby", app: "demo", object: "*", method_name: "status")
    sign_in_as(users(:user))
    get call_permissions_path(path: "fmruby-aaaaaa/demo/screen"), as: :json
    assert_equal [ "say" ], response.parsed_body.map { _1["method"] }
    get call_permissions_path(path: "linux/demo/screen"), as: :json
    assert_equal [], response.parsed_body
  end
end
