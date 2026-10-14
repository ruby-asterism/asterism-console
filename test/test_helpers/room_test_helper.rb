require "tmpdir"
require "securerandom"

# Rooms in tests (G2): a stand-in signer (a CA of its own and a rooms'
# signing key, what bin/signer does without the process), room slots made
# the way bin/asterism setup makes them (Relay::RoomSlots), and the rooms'
# directory in a temporary one.
module RoomTestHelper
  class FakeSigner
    attr_reader :room_key, :tokens

    def initialize(dir)
      @ca = Relay::CertAuthority.create(dir)
      @room_key = OpenSSL::PKey.generate_key("ED25519")
      @tokens = []
    end

    def ca_pem = @ca.cert.to_pem

    def sign(name:, csr: nil, spki: nil, dns: [], ips: [], days: 90)
      c = @ca.sign(name, csr || spki, dns: dns, ips: ips, days: days)
      { "certificate" => c.to_pem, "serial" => c.serial.to_s(16) }
    end

    def kid = Relay::RoomToken.kid(@room_key)

    def room_keys
      { "current" => kid, "keys" => [ { "kid" => kid, "public_key" => @room_key.public_to_pem, "made_at" => "x" } ] }
    end

    def room_token(room:, slot:, exp:, max:)
      claims = { "v" => 1, "kid" => kid, "room" => room, "slot" => slot, "exp" => exp.to_i, "max" => max,
                 "jti" => SecureRandom.uuid }
      t = Relay::RoomToken.sign(@room_key, claims)
      @tokens << t
      { "token" => t, "kid" => kid, "jti" => claims["jti"], "exp" => exp.to_i }
    end
  end

  def setup_rooms(slots: 2)
    @rooms_tmp = Dir.mktmpdir
    @room_env = { "ASTERISM_ROOMS_DIR" => File.join(@rooms_tmp, "rooms"), "ASTERISM_ROOM_SLOTS" => slots.to_s }
    @room_env_old = @room_env.keys.to_h { [ _1, ENV[_1] ] }
    @room_env.each { ENV[_1] = _2 }
    @signer = FakeSigner.new(File.join(@rooms_tmp, "ca"))
    Relay::Issuer.signer = @signer
    Room.signer = @signer
    Relay::RoomSlots.ensure!(@signer.ca_pem)
  end

  def teardown_rooms
    Relay::Issuer.signer = nil
    Room.signer = nil
    @room_env_old&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    FileUtils.rm_rf(@rooms_tmp) if @rooms_tmp
  end
end
