require "test_helper"

class ConsoleChannelTest < ActionCable::Channel::TestCase
  setup { stub_connection(current_user: users(:user), remote_ip: "192.0.2.10") }

  test "the graph's stream, the plots' and the logs'; nothing else" do
    subscribe
    assert_has_stream "console"
    assert_has_stream "console:graph"
    refute_includes subscription.streams, "console:graph:rooms"
    unsubscribe
    subscribe(stream: "plots")
    assert_has_stream "console:plots"
    unsubscribe
    subscribe(stream: "logs")
    assert_has_stream "console:logs"
    unsubscribe
    subscribe(stream: "console:secret")
    assert subscription.rejected?
  end

  test "the graph with the rooms for an admin who may use the admin pages from there; without them otherwise" do
    admin = users(:admin)
    stub_connection(current_user: admin, remote_ip: "192.0.2.10")
    subscribe
    assert_has_stream "console:graph:rooms"
    refute_includes subscription.streams, "console:graph"
    unsubscribe
    with_env("CONSOLE_ADMIN_NETS" => "198.51.100.0/24") do
      stub_connection(current_user: admin, remote_ip: "192.0.2.10")
      subscribe
      assert_has_stream "console:graph"
      refute_includes subscription.streams, "console:graph:rooms"
    end
  end

  test "send_graph: the admins' diff and the others' on their own streams" do
    assert_broadcasts("console:graph:rooms", 1) do
      assert_broadcasts("console:graph", 1) { ConsoleChannel.send_graph(4, { "a" => 1 }, { "a" => 0 }) }
    end
    assert_equal 0, ActiveSupport::JSON.decode(broadcasts("console:graph").last)["diff"]["a"]
  end

  def with_env(vars)
    old = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { ENV[_1] = _2 }
    yield
  ensure
    old.each { ENV[_1] = _2 }
  end
end
