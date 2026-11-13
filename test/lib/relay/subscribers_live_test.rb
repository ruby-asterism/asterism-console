require "test_helper"
require "asterism"
require "socket"
require "rbconfig"
require "json"
require Rails.root.join("lib/relay/cert_authority").to_s

# The subscribers' declarations through a real router with the access
# control Relay::CloudConfig generates (mutual TLS, a throwaway CA): a
# protocol 2 topic goes out through a declared publisher, which sends only
# while the router has told it of a matching subscriber. A reader whose key
# has a wildcard node (asterism/*/games/*/state, the commentary's
# */@shared/spectate/**) and no named reader beside it gets the values
# with the shared rule subscribers_out, and nothing without it (the
# router dropped the declaration on its way to the publisher).
class Relay::SubscribersLiveTest < ActiveSupport::TestCase
  ROUTER = <<~'RUBY'
    require "asterism"
    s = Asterism::Zenoh::Session.open(nil, config: File.read(ARGV[0]))
    STDOUT.puts "ready"
    STDOUT.flush
    STDIN.read
    s.close
  RUBY

  HOST = { "name" => "games-host", "templates" => {
    "rw" => %w[asterism/${node} asterism/${node}/games/** asterism/${node}/@profile asterism/${node}/*/@profile
               asterism/${node}/*/@status asterism/${node}/*/@pubs asterism/${node}/@shared/**],
    "read" => %w[asterism/*/game asterism/*/game/protocol/*], "ask" => [], "watch" => %w[asterism/**] } }.freeze
  VIEWER = { "name" => "viewer", "templates" => {
    "rw" => %w[asterism/${node}/** asterism/${node}/@profile],
    "read" => %w[asterism/** asterism/*/@profile asterism/*/*/@profile asterism/*/*/@status asterism/*/*/@pubs
                 asterism/*/@shared/** asterism/@shared/**],
    "ask" => %w[asterism/*/@profile asterism/*/*/*/meta asterism/*/*/@profile], "watch" => %w[asterism/**] } }.freeze
  PEERS = [ { "name" => "games", "kind" => "client", "roles" => %w[games-host], "in_acl" => true },
            { "name" => "viewer-a", "kind" => "client", "roles" => %w[viewer], "in_acl" => true } ].freeze

  setup do
    @dir = Rails.root.join("tmp", "subscribers-live-#{Process.pid}").to_s
    FileUtils.mkdir_p(@dir)
    ca = Relay::CertAuthority.create(File.join(@dir, "certs"))
    ca.issue("zenohd-cloud", dns: %w[localhost], ips: %w[127.0.0.1])
    %w[games viewer-a].each { ca.issue(_1) }
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
    FileUtils.rm_rf(@dir)
  end

  def router(without_rule: false)
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    certs = File.join(@dir, "certs")
    h = Relay::CloudConfig.new(PEERS, { "listen" => "tls/127.0.0.1:#{port}", "ca" => "#{certs}/ca.pem",
                                        "certificate" => "#{certs}/%<name>s.pem", "private_key" => "#{certs}/%<name>s.key" },
                               roles: [ HOST, VIEWER ]).to_h
    if without_rule
      h["access_control"]["policies"].each { _1["rules"].delete("subscribers_out") }
      h["access_control"]["rules"].reject! { _1["id"] == "subscribers_out" }
    end
    file = File.join(@dir, "router-#{port}.json")
    File.write(file, JSON.generate(h))
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    r = IO.popen([ RbConfig.ruby, *incs, "-e", ROUTER, file ], "r+")
    @routers << r
    assert_equal "ready", r.gets&.strip
    "tls/localhost:#{port}"
  end

  def connect(loc, name, app)
    certs = File.join(@dir, "certs")
    tls = { "transport/link/tls/root_ca_certificate" => "#{certs}/ca.pem",
            "transport/link/tls/connect_certificate" => "#{certs}/#{name}.pem",
            "transport/link/tls/connect_private_key" => "#{certs}/#{name}.key",
            "transport/link/tls/enable_mtls" => true }
    net = Asterism.connect(loc, node: name, app: app, config: tls)
    @nets << net
    net
  end

  # The values a lone reader of pattern gets while the host puts 20 on its
  # own topic and 20 on its node's shared place.
  def received(loc, pattern)
    host = connect(loc, "games", "games")
    state = host.publish("mahjong1/state")
    spectate = host.publish("spectate/mahjong1/state", shared: :node)
    reader = connect(loc, "viewer-a", "probe")
    got = []
    reader.subscribe(pattern) { |v, info| got << [ info.key, v ] }
    t = Time.now
    Asterism.poll_all while Time.now - t < 1.0 # the declarations travel
    20.times do |i|
      state.put({ "n" => i })
      spectate.put({ "n" => i })
      Asterism.poll_all
      sleep 0.02
    end
    t = Time.now
    Asterism.poll_all while Time.now - t < 0.5
    got
  end

  test "a wildcard reader with no named reader beside it gets a declared publisher's values" do
    loc = router
    got = received(loc, "*/games/*/state")
    assert_operator got.size, :>=, 15, "the table's state through asterism/*/games/*/state"
    assert got.all? { _1[0] == "asterism/games/games/mahjong1/state" }
    @nets.each(&:close)
    @nets.clear
    got = received(loc, "*/@shared/spectate/**")
    assert_operator got.size, :>=, 15, "the commentary's */@shared/spectate/**"
  end

  test "without the rule the same reader gets nothing (the router drops its declaration)" do
    loc = router(without_rule: true)
    assert_empty received(loc, "*/games/*/state")
  end
end
