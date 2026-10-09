require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "email addresses are kept in lower case, passwords are 12 characters or more" do
    u = User.new(email_address: " New@Example.COM ", password: "short")
    assert_equal "new@example.com", u.email_address
    refute u.valid?
    u.password = "long enough password"
    assert u.valid?
  end

  test "TOTP: confirmed with a code, each code taken once" do
    u = users(:user)
    refute u.otp_enabled?
    u.start_otp!
    refute u.otp_enabled?
    assert_match %r{\Aotpauth://totp/}, u.otp_uri
    refute u.confirm_otp!("000000")
    code = ROTP::TOTP.new(u.otp_secret).now
    assert u.confirm_otp!(code)
    assert u.otp_enabled?
    refute u.verify_otp(code)
    refute u.verify_otp("abc")
    u.disable_otp!
    refute u.otp_enabled?
  end
end
