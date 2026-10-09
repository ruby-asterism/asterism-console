require "test_helper"

class LogsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:user)) }

  test "the page takes ?node= for the node filter" do
    get logs_path(node: "talker")
    assert_response :success
    assert_includes response.body, 'data-logs-node-value="talker"'
  end

  test "lease and release" do
    post lease_logs_path, params: { page: "page-aaaaaaaa", wanted: [ { target: "*" } ] }, as: :json
    assert_response :success
    assert_equal({ "*" => [] }, StreamLease.wanted("log"))
    post release_logs_path, params: { page: "page-aaaaaaaa" }
    assert_response :no_content
    assert_empty StreamLease.wanted("log")
  end
end
