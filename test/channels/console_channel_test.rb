require "test_helper"

class ConsoleChannelTest < ActionCable::Channel::TestCase
  setup { stub_connection(current_user: users(:user)) }

  test "the graph's stream, the plots' and the logs'; nothing else" do
    subscribe
    assert_has_stream "console"
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
end
