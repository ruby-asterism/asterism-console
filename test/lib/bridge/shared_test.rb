require "test_helper"

# Bridge::Shared: the shared places' entries and keys (protocol 2), the
# senders of their attachments, and the expressions that go beside a **.
class Bridge::SharedTest < ActiveSupport::TestCase
  test "the places an entry or a key names" do
    assert_equal [ :node, "host", "spectate/t1/state" ], Bridge::Shared.place("host/@shared/spectate/t1/state")
    assert_equal [ :global, nil, "lobby" ], Bridge::Shared.place("@shared/lobby")
    [ "imu", "board1/strokes", "@shared", "host/@shared", "@shared/@x", "host/@shared/a/*", "@other/x", "a/b/@shared/x" ].each do |e|
      assert_nil Bridge::Shared.place(e), e
    end
    assert Bridge::Shared.key?("asterism/host/@shared/x")
    assert Bridge::Shared.key?("asterism/@shared/x")
    refute Bridge::Shared.key?("asterism/host/games/x")
    refute Bridge::Shared.key?("host/@shared/x"), "without asterism/"
  end

  test "a sender as an attachment names it" do
    assert_equal "host/room01", Bridge::Shared.sender("host/room01")
    [ nil, 3, "", "host", "host/room01/x", "@x/y", "*/a", "/a" ].each { assert_nil Bridge::Shared.sender(_1), _1.inspect }
  end

  test "the expressions beside a ** that would cover the places" do
    assert_equal %w[asterism/*/@shared/** asterism/@shared/**], Bridge::Shared.companions("asterism/**")
    assert_equal %w[asterism/host/@shared/**], Bridge::Shared.companions("asterism/host/**")
    [ "asterism/host/games/**", "asterism/*/*/log", "asterism/@shared/**", "demo/**", "0/**" ].each do |e|
      assert_empty Bridge::Shared.companions(e), e
    end
  end
end
