require "test_helper"

# Handles (G1.5b): the user's own short name on the network.
class UserHandleTest < ActiveSupport::TestCase
  def make(email, handle = nil)
    User.create!(email_address: email, password: "password-for-tests", handle: handle)
  end

  test "the characters, the length and the case" do
    u = users(:admin)
    %w[abc a-b-c alice2 abcdefghijklmnopqrst].each do |h|
      assert u.update(handle: h), "#{h}: #{u.errors.full_messages}"
    end
    assert u.update(handle: "  Bob  ")
    assert_equal "bob", u.reload.handle
    [ "ab", "abcdefghijklmnopqrstu", "2ab", "-ab", "ab-", "a--b", "a_b", "a.b", "a b", "ab/c", "ab*", "ä-ab" ].each do |h|
      assert_not u.update(handle: h), "#{h} should be refused"
    end
  end

  test "two users cannot have the same handle" do
    assert_not users(:admin).update(handle: "pat")
    assert_includes users(:admin).errors[:handle], "has already been taken"
    assert_not users(:admin).update(handle: "PAT")
  end

  test "a handle given up stays its owner's for the hold" do
    pat = users(:user)
    assert pat.update(handle: "patricia")
    assert_equal [ [ "pat", pat.id ] ], ReleasedHandle.pluck(:handle, :user_id)
    other = users(:admin)
    assert_not other.update(handle: "pat"), "held"
    assert_match(/given up recently/, other.errors[:handle].first)
    assert pat.update(handle: "pat"), "its owner takes it back at once"
    assert pat.update(handle: "patty")
    travel User::HANDLE_HOLD + 1.minute do
      assert other.update(handle: "pat"), "free after the hold"
    end
  end

  test "a removed user's handle is held too" do
    gone = make("gone@example.org", "gone")
    gone.destroy!
    assert_not users(:admin).update(handle: "gone")
  end

  test "the log name has no email address" do
    assert_equal "user #{users(:user).id} (pat)", users(:user).log_name
    assert_equal "user #{users(:admin).id}", users(:admin).log_name
  end
end
