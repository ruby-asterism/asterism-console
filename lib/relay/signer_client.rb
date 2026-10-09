# The console's side of the signer (bin/signer): asks it for the CA
# certificate and to sign certificate requests. The CA's key stays with the
# signer; this holds only the address and the token.
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

    # Signs csr (OpenSSL::X509::Request) for name. Returns the parsed answer
    # with "certificate" (PEM), "serial", "not_before", "not_after",
    # "fingerprint".
    def sign(name:, csr:, dns: [], ips: [], days: 90)
      req = Net::HTTP::Post.new("/sign", "Content-Type" => "application/json")
      req.body = JSON.generate("name" => name, "csr" => csr.to_pem, "dns" => dns, "ips" => ips, "days" => days)
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
