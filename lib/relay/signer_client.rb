# The console's side of the signer (bin/signer): asks it for the CA
# certificate, to sign certificate requests and to sign rooms' keys. The
# CA's key and the rooms' signing keys stay with the signer; this holds
# only the address and the token.
#
#   ASTERISM_SIGNER_URL    http://127.0.0.1:7450 (default)
#   ASTERISM_SIGNER_TOKEN  the token, or ASTERISM_SIGNER_TOKEN_FILE
#                          (default storage/relay/signer.token)
require "net/http"
require "json"
require "openssl"

module Relay
  class SignerClient
    class Error < StandardError; end

    def self.from_env(env = ENV, root: Dir.pwd)
      token = env["ASTERISM_SIGNER_TOKEN"].presence
      token ||= begin
        File.read(env["ASTERISM_SIGNER_TOKEN_FILE"].presence || File.join(root, "storage/relay/signer.token")).strip
      rescue SystemCallError
        nil
      end
      new(env.fetch("ASTERISM_SIGNER_URL", "http://127.0.0.1:7450"), token)
    end

    attr_reader :url

    def initialize(url, token)
      @url = URI(url)
      @token = token
    end

    def ca_pem
      res = request(Net::HTTP::Get.new("/ca"))
      OpenSSL::X509::Certificate.new(res.body).to_pem
    end

    # Whether the signer has a CA (false while it waits for init).
    def ca?
      ca_pem
      true
    rescue Error => e
      raise unless e.message.include?("said 404")
      false
    end

    # Asks the signer to make its CA (the first setup). Returns its
    # subject, not_after and fingerprint; Error when it has one already.
    def init(name: "Asterism Relay CA")
      req = Net::HTTP::Post.new("/init", "Content-Type" => "application/json")
      req.body = JSON.generate("name" => name)
      JSON.parse(request(req).body)
    end

    # Signs, for name, either csr (OpenSSL::X509::Request, a key made on
    # this side) or spki (an OpenSSL::PKey public key, e.g. made in a
    # browser: only the public key travels). Returns the parsed answer with
    # "certificate" (PEM), "serial", "not_before", "not_after", "fingerprint".
    def sign(name:, csr: nil, spki: nil, dns: [], ips: [], days: 90)
      raise ArgumentError, "csr: or spki:" unless csr.nil? ^ spki.nil?
      req = Net::HTTP::Post.new("/sign", "Content-Type" => "application/json")
      body = { "name" => name, "dns" => dns, "ips" => ips, "days" => days }
      if csr
        body["csr"] = csr.to_pem
      else
        body["spki"] = [ spki.public_to_der ].pack("m0")
      end
      req.body = JSON.generate(body)
      JSON.parse(request(req).body)
    end

    # The rooms' signing keys (G2), public parts only:
    # {"current" => kid or nil, "keys" => [{"kid", "public_key", "made_at"}]}.
    def room_keys
      JSON.parse(request(Net::HTTP::Get.new("/room-keys")).body)
    end

    # Makes a new current signing key for the rooms' keys.
    def make_room_key
      JSON.parse(request(Net::HTTP::Post.new("/room-keys", "Content-Type" => "application/json")).body)
    end

    # A room's key (Relay::RoomToken), signed by the signer:
    # {"token", "kid", "jti", "exp"}.
    def room_token(room:, slot:, exp:, max:)
      req = Net::HTTP::Post.new("/room-token", "Content-Type" => "application/json")
      req.body = JSON.generate("room" => room, "slot" => slot, "exp" => exp.to_i, "max" => max)
      JSON.parse(request(req).body)
    end

    private

    def request(req)
      raise Error, "no signer token (storage/relay/signer.token or ASTERISM_SIGNER_TOKEN)" if @token.to_s.empty?
      req["Authorization"] = "Bearer #{@token}"
      res = Net::HTTP.start(@url.host, @url.port, open_timeout: 3, read_timeout: 10) { |h| h.request(req) }
      return res if res.is_a?(Net::HTTPSuccess)
      msg = (JSON.parse(res.body)["error"] rescue res.body.to_s[0, 200])
      raise Error, "the signer said #{res.code}: #{msg}"
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
      raise Error, "the signer at #{@url} did not answer (#{e.class}: #{e.message})"
    end
  end
end
