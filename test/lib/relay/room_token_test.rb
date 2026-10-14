require "test_helper"
require "securerandom"

class Relay::RoomTokenTest < ActiveSupport::TestCase
  setup do
    @key = OpenSSL::PKey.generate_key("ED25519")
    @kid = Relay::RoomToken.kid(@key)
    @keys = { @kid => OpenSSL::PKey.read(@key.public_to_pem) }
  end

  def claims(**over)
    { "v" => 1, "kid" => @kid, "room" => SecureRandom.hex(8), "slot" => "03", "exp" => Time.now.to_i + 600,
      "max" => 16, "jti" => SecureRandom.uuid }.merge(over.transform_keys(&:to_s))
  end

  test "signed and checked with the public key alone; peek reads it unchecked" do
    c = claims
    t = Relay::RoomToken.sign(@key, c)
    assert_operator t.bytesize, :<, 300, "short enough for a link"
    assert_equal c, Relay::RoomToken.verify(t, @keys)
    assert_equal "03", Relay::RoomToken.peek(t)["slot"]
    assert_nil Relay::RoomToken.peek("nonsense")
  end

  test "refused: tampered, another key, an unknown kid, ended, malformed" do
    t = Relay::RoomToken.sign(@key, claims)
    body, sig = t.split(".")
    other = Relay::RoomToken.b64(JSON.generate(JSON.parse(Relay::RoomToken.unb64(body)).merge("max" => 15)))
    forged = Relay::RoomToken.sign(OpenSSL::PKey.generate_key("ED25519"), claims)
    {
      "#{other}.#{sig}" => "signature",
      forged => "signature",
      Relay::RoomToken.sign(@key, claims(exp: Time.now.to_i - 1)) => "expired",
      "" => "malformed", "a.b" => "malformed", "#{body}.#{sig}.x" => "malformed", ("x" * 2000) => "malformed"
    }.each do |tok, why|
      e = assert_raises(Relay::RoomToken::Invalid, tok[0, 20]) { Relay::RoomToken.verify(tok, @keys) }
      assert_equal why, e.message
    end
  end

  test "claims are checked when signing too" do
    assert_raises(Relay::RoomToken::Invalid) { Relay::RoomToken.sign(@key, claims(max: 17)) }
    assert_raises(Relay::RoomToken::Invalid) { Relay::RoomToken.sign(@key, claims(slot: "1")) }
    assert_raises(Relay::RoomToken::Invalid) { Relay::RoomToken.sign(@key, claims(room: "../x")) }
    assert_raises(Relay::RoomToken::Invalid) { Relay::RoomToken.sign(@key, claims.except("jti")) }
  end
end
