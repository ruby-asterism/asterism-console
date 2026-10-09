require "test_helper"

class StreamLeaseTest < ActiveSupport::TestCase
  test "a page's renewal replaces its own rows only" do
    _, errors = StreamLease.renew_page(kind: "plot", page: "page-aaaaaaaa",
                                       wanted: [ { "target" => "r_topic:0/cmd_vel", "fields" => [ "linear.x" ] },
                                                 { "target" => "key:demo/imu", "fields" => [] } ])
    assert_empty errors
    StreamLease.renew_page(kind: "plot", page: "page-bbbbbbbb", wanted: [ { "target" => "r_topic:0/cmd_vel", "fields" => [ "angular.z" ] } ])
    assert_equal({ "r_topic:0/cmd_vel" => %w[linear.x angular.z], "key:demo/imu" => [] }, StreamLease.wanted("plot"))
    StreamLease.renew_page(kind: "plot", page: "page-aaaaaaaa", wanted: [])
    assert_equal({ "r_topic:0/cmd_vel" => %w[angular.z] }, StreamLease.wanted("plot"))
    StreamLease.update_all(expires_at: 1.second.ago)
    assert_empty StreamLease.wanted("plot")
    assert_equal 0, StreamLease.count, "the expired rows are gone"
  end

  test "targets, fields and pages are checked" do
    bad = [
      [ "plot", "page-aaaaaaaa", "0/**", [] ],
      [ "plot", "page-aaaaaaaa", "key:@/*/router", [] ],
      [ "plot", "page-aaaaaaaa", "key:a b", [] ],
      [ "plot", "page-aaaaaaaa", "r_topic:0/cmd_vel", [ "a..b" ] ],
      [ "plot", "page-aaaaaaaa", "r_topic:0/cmd_vel", Array.new(17) { "f#{_1}" } ],
      [ "plot", "short", "r_topic:0/cmd_vel", [] ],
      [ "log", "page-aaaaaaaa", "r_topic:0/rosout", [] ],
      [ "log", "page-aaaaaaaa", "*", [ "x" ] ],
      [ "other", "page-aaaaaaaa", "*", [] ]
    ]
    bad.each do |kind, page, target, fields|
      _, errors = StreamLease.renew_page(kind: kind, page: page, wanted: [ { "target" => target, "fields" => fields } ])
      refute_empty errors, [ kind, page, target, fields ].inspect
    end
    assert_equal 0, StreamLease.count
  end

  test "release and the bridge's meta" do
    StreamLease.renew_page(kind: "log", page: "page-aaaaaaaa", wanted: [ { "target" => "*" } ])
    assert_equal({ "*" => [] }, StreamLease.wanted("log"))
    StreamLease.renew_page(kind: "plot", page: "page-aaaaaaaa", wanted: [ { "target" => "r_topic:0/a", "fields" => [] } ])
    StreamLease.write_meta("plot", "r_topic:0/a", { "type" => "std_msgs/msg/Float64" })
    assert_equal "std_msgs/msg/Float64", StreamLease.find_by(kind: "plot").meta_value["type"]
    StreamLease.release(kind: "log", page: "page-aaaaaaaa")
    assert_empty StreamLease.wanted("log")
    assert_equal 1, StreamLease.count
  end
end
