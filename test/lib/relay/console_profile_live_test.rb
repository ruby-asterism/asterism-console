require "test_helper"
require "asterism"
require "socket"
require "rbconfig"
require "json"
require Rails.root.join("lib/relay/cert_authority").to_s

# The console's own profile through a real router with the access control
# Relay::CloudConfig generates (mutual TLS, a throwaway CA): another
# member's query of asterism/<console node>/@profile gets the console's
# reply (kind console) and its put reaches a subscriber. The console's
# certificate still cannot answer or put another node's profile.
class Relay::ConsoleProfileLiveTest < ActiveSupport::TestCase
  ROUTER = <<~'RUBY'
    require "asterism"
    s = Asterism::Zenoh::Session.open(nil, config: File.read(ARGV[0]))
    STDOUT.puts "ready"
    STDOUT.flush
    STDIN.read
    s.close
  RUBY

  VIEWER = { "name" => "viewer", "templates" => {
    "rw" => %w[asterism/${node}/** asterism/${node}/@profile],
    "read" => %w[asterism/** asterism/*/@profile asterism/*/*/@profile],
    "ask" => %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile], "watch" => %w[asterism/**] } }.freeze
  PEERS = [ { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "in_acl" => true },
            { "name" => "viewer-a", "kind" => "client", "roles" => %w[viewer], "in_acl" => true } ].freeze
  NODES = %w[cprofile-console cprofile-other].freeze

  setup do
    @dir = Rails.root.join("tmp", "console-profile-live-#{Process.pid}").to_s
    FileUtils.mkdir_p(@dir)
    ca = Relay::CertAuthority.create(File.join(@dir, "certs"))
    ca.issue("zenohd-cloud", dns: %w[localhost], ips: %w[127.0.0.1])
    %w[console viewer-a].each { ca.issue(_1) }
    @routers = []
    @nets = []
  end

  teardown do
    @nets.each { _1.close rescue nil }
    @routers.each do |r|
      r.close_write rescue nil
      r.read rescue nil
      r.close rescue nil
    end
    profiles = Asterism.instance_variable_get(:@node_profiles)
    NODES.each { profiles&.delete(_1) }
    FileUtils.rm_rf(@dir)
  end

  def router
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    certs = File.join(@dir, "certs")
    h = Relay::CloudConfig.new(PEERS, { "listen" => "tls/127.0.0.1:#{port}", "ca" => "#{certs}/ca.pem",
                                        "certificate" => "#{certs}/%<name>s.pem", "private_key" => "#{certs}/%<name>s.key",
                                        "console_node" => NODES[0] },
                               roles: [ VIEWER ]).to_h
    file = File.join(@dir, "router-#{port}.json")
    File.write(file, JSON.generate(h))
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    r = IO.popen([ RbConfig.ruby, *incs, "-e", ROUTER, file ], "r+")
    @routers << r
    assert_equal "ready", r.gets&.strip
    "tls/localhost:#{port}"
  end

  def connect(loc, cert, node, app)
    certs = File.join(@dir, "certs")
    tls = { "transport/link/tls/root_ca_certificate" => "#{certs}/ca.pem",
            "transport/link/tls/connect_certificate" => "#{certs}/#{cert}.pem",
            "transport/link/tls/connect_private_key" => "#{certs}/#{cert}.key",
            "transport/link/tls/enable_mtls" => true }
    net = Asterism.connect(loc, node: node, app: app, config: tls)
    @nets << net
    net
  end

  def settle(seconds)
    t = Time.now
    Asterism.poll_all while Time.now - t < seconds
  end

  # The viewer's view of a node the console's certificate speaks for: the
  # profile it answers and the puts that reach a subscriber when it
  # changes its name.
  def seen(loc, node)
    console = connect(loc, "console", node, "console")
    console.profile(kind: :console)
    viewer = connect(loc, "viewer-a", "viewer-a", "probe")
    puts = []
    viewer.subscribe("#{node}/@profile") { |v| puts << v }
    settle(1.0) # the declarations travel
    answer = viewer.profile_of(node, icon: false, timeout: 1.5)
    console.profile(name: "Hub")
    settle(0.5)
    [ answer, puts ]
  end

  test "another member gets the console's own profile: its reply to a query and its put" do
    answer, puts = seen(router, NODES[0])
    assert_equal "console", answer&.dig("kind"), "the reply to asterism/#{NODES[0]}/@profile"
    assert puts.any? { _1.is_a?(Hash) && _1["kind"] == "console" && _1["name"] == "Hub" }, "the put: #{puts.inspect}"
  end

  test "the console's certificate cannot answer or put another node's profile" do
    answer, puts = seen(router, NODES[1])
    assert_nil answer, "no reply from asterism/#{NODES[1]}/@profile"
    assert_empty puts
  end
end
