require "test_helper"

class WatchesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:user)) }

  include ActionCable::TestHelper

  test "watch, list and stop" do
    assert_broadcasts(ConsoleChannel::STREAM, 1) do
      post watches_path, params: { key: " fmrb/test/out " }, as: :json
    end
    assert_response :created
    id = response.parsed_body["id"]
    post watches_path, params: { key: "fmrb/test/out" }, as: :json
    assert_equal id, response.parsed_body["id"], "the same key is one watch"

    get watches_path, as: :json
    assert_equal [ "fmrb/test/out" ], response.parsed_body.map { _1["key"] }

    delete watch_path(id)
    assert_response :no_content
    assert_equal 0, Watch.count
  end

  test "a key with spaces is refused" do
    post watches_path, params: { key: "a b" }, as: :json
    assert_response :unprocessable_content
  end
end
