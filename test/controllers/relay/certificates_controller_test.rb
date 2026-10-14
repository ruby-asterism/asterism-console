require "test_helper"
require "tmpdir"
require "rubygems/package"

class Relay::CertificatesControllerTest < ActionDispatch::IntegrationTest
  # Signs with a CA of its own (what bin/signer does, without the process).
  class FakeSigner
    def initialize(dir)
      @ca = Relay::CertAuthority.create(dir)
    end

    def ca_pem = @ca.cert.to_pem

    attr_reader :seen

    def sign(name:, csr: nil, spki: nil, dns: [], ips: [], days: 90)
      (@seen ||= []) << { name: name, csr: csr, spki: spki }
      c = @ca.sign(name, csr || spki, dns: dns, ips: ips, days: days)
      { "certificate" => c.to_pem, "serial" => c.serial.to_s(16) }
    end
  end

  setup do
    @dir = Dir.mktmpdir
    Relay::Issuer.signer = FakeSigner.new(@dir)
    @peer = RelayPeer.create!(name: "w2bot", kind: "client", rw_keys: "asterism/**", cert_days: 10)
    sign_in_as(users(:admin))
  end

  teardown do
    Relay::Issuer.signer = nil
    FileUtils.rm_rf(@dir)
  end

  def spki(key = @key) = [ key.public_to_der ].pack("m0")

  def with_env(vars)
    old = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { ENV[_1] = _2 }
    yield
  ensure
    old.each { ENV[_1] = _2 }
  end

  setup { @key = OpenSSL::PKey::EC.generate("prime256v1") }

  test "issuing takes the public key only and answers with the certificate, never a key" do
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    assert_response :created
    assert_includes response.headers["Cache-Control"], "no-store"
    ans = response.parsed_body
    cert = OpenSSL::X509::Certificate.new(ans["certificate"])
    assert cert.check_private_key(@key), "the certificate is for the browser's key"
    refute_includes response.body, "PRIVATE KEY"
    assert_includes ans["ca"], "BEGIN CERTIFICATE"
    assert_includes ans["zenoh_config"], "w2bot.key"
    seen = Relay::Issuer.signer.seen.sole
    assert_nil seen[:csr]
    refute seen[:spki].private?, "the signer got a public key"
    rec = @peer.certificates.sole
    assert_equal [ "signer", users(:admin), "w2bot" ], [ rec.source, rec.issued_by, rec.common_name ]
    assert_in_delta 10.days.from_now, rec.not_after, 120
    assert @peer.reload.in_acl?
    refute_includes (RelayCertificate.all.map(&:attributes) + RelayPeer.all.map(&:attributes)).to_s, "PRIVATE KEY"

    get relay_peer_path(@peer)
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "[data-controller=issue]"
    assert_select "td code", rec.serial
    assert_select ".badge", "in the ACL"
  end

  test "what the .tar is made of (O1): asterism.json, a client's or a home router's configuration, Save all" do
    with_env("ASTERISM_RELAY_PUBLIC_ENDPOINT" => "tls/router.example.org:7448") do
      post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
      assert_response :created
      ans = response.parsed_body
      rec = @peer.certificates.sole
      assert_equal({ "format" => 1, "name" => "w2bot", "kind" => "client", "router" => "tls/router.example.org:7448",
                     "serial" => rec.serial, "not_after" => rec.not_after.utc.iso8601, "fingerprint" => rec.fingerprint,
                     "console" => "http://www.example.com" }, ans["info"].except("issued_at"))
      refute_includes ans["info"].to_s, "PRIVATE"
      assert_includes ans["zenoh_config"], 'mode: "client"'
      assert_includes ans["zenoh_config"], "credentials: \"w2bot.tar\""

      home = RelayPeer.create!(name: "home-a", kind: "router", cert_days: 10)
      post relay_peer_certificates_path(home), params: { spki: spki }, as: :json
      cfg = response.parsed_body["zenoh_config"]
      assert_includes cfg, 'mode: "router"'
      assert_includes cfg, 'listen: { endpoints: ["tcp/[::]:7447"] }'
      assert_includes cfg, 'connect: { endpoints: ["tls/router.example.org:7448"] }'
      assert_includes cfg, 'connect_private_key: "home-a.key"'
      assert_includes cfg, 'metadata: { name: "home-a" }'
      assert_equal "router", response.parsed_body.dig("info", "kind")

      get relay_peer_path(home)
      assert_select "button[data-action='issue#saveAll']", "Save all (.tar)"
      assert_select "button[data-action='issue#save']", 4
    end
  end

  test "a private key sent by mistake is refused and not kept" do
    post relay_peer_certificates_path(@peer), params: { spki: [ @key.private_to_der ].pack("m0") }, as: :json
    assert_response :unprocessable_content
    assert_match(/private key/, response.parsed_body["error"])
    assert_equal 0, @peer.certificates.count
    post relay_peer_certificates_path(@peer), params: {}, as: :json
    assert_response :bad_request
  end

  test "the public key does not reach the log" do
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.logger(io)
    ActionController::Base.logger = Rails.logger
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    assert_response :created
    refute_includes io.string, spki[0, 40]
    refute_includes io.string, "BEGIN CERTIFICATE"
  ensure
    Rails.logger = old
    ActionController::Base.logger = old
  end

  test "revoking takes the peer out of the next ACL" do
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    cert = @peer.certificates.sole
    patch revoke_relay_peer_certificate_path(@peer, cert)
    assert_redirected_to relay_peer_path(@peer)
    assert_equal [ "revoked", users(:admin) ], [ cert.reload.status, cert.revoked_by ]
    refute @peer.reload.in_acl?
    assert_equal [], Relay::Applier.config_for.subject_names
  end

  test "a disabled peer gets no certificate; a signer that does not answer is said so" do
    @peer.update!(enabled: false)
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    assert_match(/disabled/, response.parsed_body["error"])
    @peer.update!(enabled: true)
    Relay::Issuer.signer = Relay::SignerClient.new("http://127.0.0.1:1", "x" * 32)
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    assert_match(/did not answer/, response.parsed_body["error"])
    assert_equal 0, @peer.certificates.count
  end

  test "issuing answers with the banner, the ledger and what comes next, for the page to put in place" do
    Dir.mktmpdir do |gen|
      with_env("ASTERISM_RELAY_GENERATED_DIR" => gen) do
        # The cloud router runs the registry as it is (w2bot has no certificate, so it is not in the ACL).
        File.write(Relay::Settings.config_path, Relay::Applier.config_for.text(by: "admin@example.com"))
        get relay_peer_path(@peer)
        assert_select "#relay-tabs .tabs-aside", /runs this registry/
        assert_select "#relay-tabs .apply-banner", 0
        assert_select "#peer-cert-status [data-test=cert-next]",
                      /No certificate yet: issue one below; it joins the ACL when you apply/
        assert_select "#peer-acl .badge", "no valid certificate"
        assert_select "[data-issue-target=next]"

        post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
        assert_response :created
        ans = response.parsed_body
        next_step = Nokogiri::HTML5.fragment(ans["next"])
        assert_match(/Saved\? Next: apply/, next_step.text)
        assert_equal new_relay_apply_path, next_step.at_css("a.button")["href"]
        assert_equal "Review and apply", next_step.at_css("a.button").text
        parts = ans["replace"].transform_values { Nokogiri::HTML5.fragment(_1) }
        assert_equal %w[peer-acl peer-cert-status peer-certs relay-tabs], parts.keys.sort
        parts.each { |id, frag| assert_equal id, frag.element_children.sole["id"], "#{id} replaces itself" }
        tabs = parts["relay-tabs"]
        assert_match(/Changes not yet applied/, tabs.at_css(".apply-banner").text)
        assert_equal new_relay_apply_path, tabs.at_css(".apply-banner a")["href"]
        assert_nil tabs.at_css(".tabs-aside"), "no longer says the cloud router runs this registry"
        assert_equal "in the ACL", parts["peer-acl"].at_css(".badge").text
        assert_nil parts["peer-cert-status"].at_css("[data-test=cert-next]"), "it has a certificate now"
        assert_equal @peer.certificates.sole.serial, parts["peer-certs"].at_css("tbody tr code").text

        # A reload says the same.
        get relay_peer_path(@peer)
        assert_select "#relay-tabs .apply-banner", /Changes not yet applied/
      end
    end
  end

  test "issuing again for a peer the cloud router already lets in: nothing to apply" do
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    Dir.mktmpdir do |gen|
      with_env("ASTERISM_RELAY_GENERATED_DIR" => gen) do
        File.write(Relay::Settings.config_path, Relay::Applier.config_for.text)
        post relay_peer_certificates_path(@peer), params: { spki: spki(OpenSSL::PKey::EC.generate("prime256v1")) }, as: :json
        assert_response :created
        assert_match(/Nothing to apply/, response.parsed_body["next"])
        assert_includes response.parsed_body["replace"]["relay-tabs"], "runs this registry"
      end
    end
  end

  test "a peer whose certificates are all revoked is told to issue one" do
    post relay_peer_certificates_path(@peer), params: { spki: spki }, as: :json
    @peer.certificates.sole.revoke!(users(:admin))
    get relay_peer_path(@peer)
    assert_select "#peer-cert-status [data-test=cert-next]", /No valid certificate \(expired or revoked\): issue one below/
  end
end
