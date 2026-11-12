# A CA certificate as made before 0.3.20 (3650 days) over the CA's key in
# dir, written as its ca.pem (what a server has before the update's setup
# makes it again without an end). Returns it.
module DatedCa
  module_function

  def make!(dir)
    ca = Relay::CertAuthority.load(dir)
    old = OpenSSL::X509::Certificate.new(ca.cert.to_pem)
    old.serial = Relay::CertAuthority.serial
    old.not_after = Time.now + 3650 * 86_400
    old.sign(ca.key, OpenSSL::Digest.new("SHA256"))
    File.write(File.join(dir, "ca.pem"), old.to_pem)
    old
  end
end
