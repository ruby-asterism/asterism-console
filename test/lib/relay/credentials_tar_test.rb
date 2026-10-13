require "test_helper"
require "open3"
require "rubygems/package"

# The .tar "Save all (.tar)" makes in the browser (app/javascript/lib/
# credentials_tar.js, O1), made here by Node from the same module and read
# back with Ruby's tar reader (what the asterism gem's credentials: uses):
# the files, their modes, asterism.json. Skipped without node.
class CredentialsTarTest < ActiveSupport::TestCase
  MODULE = Rails.root.join("app/javascript/lib/credentials_tar.js")

  # Node runs the module (as a data: URL, so it is read as an ES module)
  # on the parts given as JSON on stdin and writes the tar to stdout.
  SCRIPT = <<~JS.freeze
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    import("data:text/javascript;base64," + Buffer.from(src).toString("base64")).then((m) => {
      const parts = JSON.parse(fs.readFileSync(0, "utf8"))
      process.stdout.write(Buffer.from(m.credentialsTar(parts, 1760000000)))
    })
  JS

  def node
    @node ||= begin
      out, st = Open3.capture2e("node", "--version")
      st.success? ? "node" : nil
    rescue SystemCallError
      nil
    end
  end

  def make(parts)
    skip "no node to run the browser module" unless node
    out, err, st = Open3.capture3(node, "-e", SCRIPT, MODULE.to_s, stdin_data: JSON.generate(parts), binmode: true)
    assert st.success?, err
    out
  end

  def entries(tar)
    got = {}
    Gem::Package::TarReader.new(StringIO.new(tar)) do |r|
      r.each { |e| got[e.full_name] = [ e.header.typeflag, e.header.mode & 0o7777, e.file? ? e.read.to_s : nil ] }
    end
    got
  end

  PARTS = {
    "name" => "home-a", "key" => "-----BEGIN PRIVATE KEY-----\nAAA\n-----END PRIVATE KEY-----\n",
    "cert" => "-----BEGIN CERTIFICATE-----\nBBB\n-----END CERTIFICATE-----\n",
    "ca" => "-----BEGIN CERTIFICATE-----\nCCC\n-----END CERTIFICATE-----\n",
    "config" => "{ mode: \"router\" }\n",
    "info" => { "format" => 1, "name" => "home-a", "kind" => "router", "router" => "tls/router.example.org:7448",
                "not_after" => "2027-10-13T00:00:00Z", "console" => "https://asterism.example.org" }
  }.freeze

  test "the files under <name>/, the key 0600 and the rest 0644" do
    tar = make(PARTS)
    assert_equal 0, tar.bytesize % 512
    got = entries(tar)
    assert_equal %w[home-a/ home-a/home-a.key home-a/home-a.pem home-a/ca.pem home-a/zenoh.json5 home-a/asterism.json],
                 got.keys
    assert_equal [ "5", 0o755 ], got["home-a/"][0, 2]
    assert_equal [ "0", 0o600, PARTS["key"] ], got["home-a/home-a.key"]
    assert_equal [ "0", 0o644, PARTS["cert"] ], got["home-a/home-a.pem"]
    assert_equal [ "0", 0o644, PARTS["ca"] ], got["home-a/ca.pem"]
    assert_equal [ "0", 0o644, PARTS["config"] ], got["home-a/zenoh.json5"]
    info = JSON.parse(got["home-a/asterism.json"][2])
    assert_equal PARTS["info"], info
    assert_equal 0o644, got["home-a/asterism.json"][1]
  end

  test "tar itself extracts it with the modes" do
    skip "no tar" unless system("tar --version", out: File::NULL, err: File::NULL)
    tar = make(PARTS)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "home-a.tar")
      File.binwrite(path, tar)
      assert system("tar", "-xf", path, "-C", dir)
      assert_equal 0o600, File.stat(File.join(dir, "home-a/home-a.key")).mode & 0o777
      assert_equal PARTS["cert"], File.read(File.join(dir, "home-a/home-a.pem"))
      assert_equal "tls/router.example.org:7448", JSON.parse(File.read(File.join(dir, "home-a/asterism.json")))["router"]
    end
  end
end
