require "test_helper"

# The WebSocket takes the sign-in cookie; without it the connection (and so
# every graph diff, answer and watched value) is refused.
class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "refused without a session" do
    assert_reject_connection { connect }
  end

  test "refused with a session id that is not signed" do
    cookies["session_id"] = Session.create!(user: users(:user)).id.to_s
    assert_reject_connection { connect }
  end

  test "refused with an old session" do
    s = Session.create!(user: users(:user), created_at: (Session::LIFETIME + 1.minute).ago)
    cookies.signed[:session_id] = s.id
    assert_reject_connection { connect }
  end

  test "taken with a signed-in user" do
    cookies.signed[:session_id] = Session.create!(user: users(:user)).id
    connect
    assert_equal users(:user), connection.current_user
  end
end
