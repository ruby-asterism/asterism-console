require "test_helper"

class RateLeaseTest < ActiveSupport::TestCase
  test "* or a topic id, renewed in place, wanted while live" do
    assert RateLease.renew("*")
    assert RateLease.renew("r_topic:0/camera/image_raw")
    refute RateLease.renew("0/**")
    refute RateLease.renew("r_topic:0/a b")
    refute RateLease.renew("r_topic:x/chatter")
    assert_no_difference -> { RateLease.count } do
      RateLease.renew("*")
    end
    assert_equal [ "*", "r_topic:0/camera/image_raw" ], RateLease.wanted
    RateLease.where(key: "*").update_all(expires_at: 1.second.ago)
    assert_equal [ "r_topic:0/camera/image_raw" ], RateLease.wanted
    assert_equal 1, RateLease.count, "the expired one is gone"
    assert_equal "0/camera/image_raw/**", RateLease.key_expr("r_topic:0/camera/image_raw")
  end
end
