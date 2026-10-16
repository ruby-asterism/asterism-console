# The key of a room (G2): who holds it may join that room's key space on
# the cloud router, through the door, until it ends. The console asks the
# signer to sign it (the signing key is the signer's only, like the CA's);
# the door checks it with the public keys alone and never asks the console.
#
#   <base64url(claims JSON)>.<base64url(Ed25519 signature of the first part)>
#
# Claims (all of them required):
#   v     1
#   kid   which signing key (Relay::RoomToken.kid of its public key); the
#         door keeps several, so a key can be replaced without a gap
#   room  the room's ID (Room#uid: 16 hex, random)
#   slot  the room slot it is on ("01".."99"): its key space is
#         room/<slot>/** and the door connects with one of its seats' certificates
#   exp   when it ends (Unix seconds)
#   max   connections the room may have at once (1..MAX_CONNECTIONS)
#   jti   a random ID (UUID): no two keys are the same string
#
# No role is in it: a key lets one into a room, what one may do there is
# the room's own business (doc: docs/rooms.md). Plain Ruby (the standard
# library), so the signer and the door need no Rails.
require "openssl"
require "json"
require "base64"
require "digest"

module Relay
  module RoomToken
    VERSION = 1
    # The longest a room is open (hours): the signer refuses a later end,
    # the door cuts a connection at this age whatever the key says.
    MAX_HOURS = 24
    MAX_CONNECTIONS = 16
    MAX_SIZE = 1024
    SLOT = /\A[0-9]{2}\z/
    ROOM = /\A[0-9a-f]{16}\z/
    KID = /\A[0-9a-f]{16}\z/
    JTI = /\A[0-9a-f-]{36}\z/
    CLAIMS = %w[v kid room slot exp max jti].freeze

    class Invalid < StandardError; end

    module_function

    def b64(data)
      Base64.urlsafe_encode64(data, padding: false)
    end

    def unb64(text)
      raise Invalid, "not base64url" unless text.match?(/\A[A-Za-z0-9_-]*\z/)
      Base64.urlsafe_decode64(text + "=" * ((4 - text.size % 4) % 4))
    rescue ArgumentError
      raise Invalid, "not base64url"
    end

    # The key ID of an Ed25519 public key: 16 hex of the SHA-256 of its DER.
    def kid(public_key)
      Digest::SHA256.hexdigest(public_key.public_to_der)[0, 16]
    end

    # Signs claims (a Hash with every claim) with an Ed25519 private key.
    def sign(private_key, claims)
      check_claims!(claims)
      body = b64(JSON.generate(CLAIMS.to_h { [ _1, claims[_1] ] }))
      "#{body}.#{b64(private_key.sign(nil, body))}"
    end

    # The claims, unchecked (the browser build reads its slot this way; it
    # trusts nothing in it). nil when it is not a key at all.
    def peek(token)
      body, = split(token)
      claims = JSON.parse(unb64(body))
      claims.is_a?(Hash) ? claims : nil
    rescue Invalid, JSON::ParserError
      nil
    end

    # Checks a key against the public keys ({kid => OpenSSL::PKey}).
    # Returns the claims, or raises Invalid with :malformed / :signature
    # (forged, tampered, an unknown kid) / :expired. The room's own state
    # (closed early, moved off its slot) is the door's to check.
    def verify(token, keys, now: Time.now.to_i)
      body, sig = split(token)
      claims = begin
        JSON.parse(unb64(body))
      rescue JSON::ParserError, Invalid
        raise Invalid, "malformed"
      end
      raise Invalid, "malformed" unless claims.is_a?(Hash)
      begin
        check_claims!(claims)
      rescue Invalid
        raise Invalid, "malformed"
      end
      key = keys[claims["kid"]] or raise Invalid, "signature"
      ok = begin
        key.verify(nil, unb64(sig), body)
      rescue OpenSSL::PKey::PKeyError, Invalid
        false
      end
      raise Invalid, "signature" unless ok
      raise Invalid, "expired" if claims["exp"] <= now
      claims
    end

    def split(token)
      t = token.to_s
      raise Invalid, "malformed" if t.empty? || t.bytesize > MAX_SIZE
      body, sig, rest = t.split(".", 3)
      raise Invalid, "malformed" if body.to_s.empty? || sig.to_s.empty? || rest
      [ body, sig ]
    end

    def check_claims!(c)
      raise Invalid, "claims must be a Hash" unless c.is_a?(Hash)
      missing = CLAIMS - c.keys
      raise Invalid, "missing #{missing.join(', ')}" if missing.any?
      raise Invalid, "v must be #{VERSION}" unless c["v"] == VERSION
      raise Invalid, "bad kid" unless c["kid"].is_a?(String) && c["kid"].match?(KID)
      raise Invalid, "bad room" unless c["room"].is_a?(String) && c["room"].match?(ROOM)
      raise Invalid, "bad slot" unless c["slot"].is_a?(String) && c["slot"].match?(SLOT)
      raise Invalid, "bad exp" unless c["exp"].is_a?(Integer) && c["exp"].positive?
      raise Invalid, "bad max" unless c["max"].is_a?(Integer) && c["max"].between?(1, MAX_CONNECTIONS)
      raise Invalid, "bad jti" unless c["jti"].is_a?(String) && c["jti"].match?(JTI)
      c
    end
  end
end
