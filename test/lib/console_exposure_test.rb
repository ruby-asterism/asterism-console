require "test_helper"

class ConsoleExposureTest < ActiveSupport::TestCase
  test "loopback addresses" do
    %w[127.0.0.1 ::1 [::1] localhost].each { assert ConsoleExposure.loopback?(_1), _1 }
    assert ConsoleExposure.loopback?(nil)
    %w[0.0.0.0 :: 192.0.2.10 example.org].each { refute ConsoleExposure.loopback?(_1), _1 }
  end

  test "listening beyond loopback needs a user" do
    assert_equal :loopback, ConsoleExposure.check!("127.0.0.1")
    assert_equal :exposed, ConsoleExposure.check!("0.0.0.0")
    Session.delete_all
    BridgeRequest.delete_all
    User.delete_all
    assert_raises(RuntimeError) { ConsoleExposure.check!("0.0.0.0") }
    assert_equal :loopback, ConsoleExposure.check!("127.0.0.1")
  end
end

class ConsoleExposureHostTest < ActiveSupport::TestCase
  test "the address comes from -b, then BINDING / CONSOLE_BIND" do
    assert_equal "0.0.0.0", ConsoleExposure.listen_host(%w[server -b 0.0.0.0], {})
    assert_equal "0.0.0.0", ConsoleExposure.listen_host(%w[server --binding=0.0.0.0], {})
    assert_equal "::", ConsoleExposure.listen_host(%w[server -b::], {})
    assert_equal "192.0.2.10", ConsoleExposure.listen_host(%w[server], "BINDING" => "192.0.2.10")
    assert_equal "192.0.2.11", ConsoleExposure.listen_host(%w[server], "CONSOLE_BIND" => "192.0.2.11")
    assert_nil ConsoleExposure.listen_host(%w[server], {})
  end
end
