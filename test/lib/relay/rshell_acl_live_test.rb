require "test_helper"
require "asterism"
require "socket"
require "rbconfig"
require "json"
require_relative "../../test_helpers/fake_rshell"
require Rails.root.join("lib/relay/cert_authority").to_s

# The remote shell's calls through a real router with the access control
# Relay::CloudConfig generates (mutual TLS, a throwaway CA): a machine
# whose row lets the console's remote shell in (managed, so its transfer
# keys are there) exposes transfer/rshell and transfer/inbox; the console
# (rw asterism/**) opens a session; another member whose role may call any
# object under its own name (asterism/*/*/*/call/${node}) still reaches
# the inbox but not the remote shell (no_rshell_calls), even though the
# machine itself would let it in.
class Relay::RShellAclLiveTest < ActiveSupport::TestCase
  ROUTER = <<~'RUBY'
    require "asterism"
    s = Asterism::Zenoh::Session.open(nil, config: File.read(ARGV[0]))
    STDOUT.puts "ready"
    STDOUT.flush
    STDIN.read
    s.close
  RUBY

  CALLER = { "name" => "caller", "templates" => {
    "rw" => %w[asterism/${node}/**], "read" => %w[asterism/**], "ask" => %w[asterism/*/*/*/call/${node} asterism/*/*/*/meta],
    "watch" => %w[asterism/**] } }.freeze
  PEERS = [ { "name" => "console", "kind" => "client", "rw" => %w[asterism/**], "in_acl" => true },
            { "name" => "fmruby-aaaaaa", "kind" => "client", "in_acl" => true, "receivers_managed" => true },
            { "name" => "pc", "kind" => "client", "roles" => %w[caller], "in_acl" => true } ].freeze

  setup do
    @dir = Rails.root.join("tmp", "rshell-acl-live-#{Process.pid}").to_s
    FileUtils.mkdir_p(@dir)
    ca = Relay::CertAuthority.create(File.join(@dir, "certs"))
    ca.issue("zenohd-cloud", dns: %w[localhost], ips: %w[127.0.0.1])
    %w[console fmruby-aaaaaa pc].each { ca.issue(_1) }
    @nets = []
  end

  teardown do
    @nets.each { _1.close rescue nil }
    if @router
      @router.close_write rescue nil
      @router.read rescue nil
      @router.close rescue nil
    end
    FileUtils.rm_rf(@dir)
  end

  def router(without_deny: false)
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    certs = File.join(@dir, "certs")
    h = Relay::CloudConfig.new(PEERS, { "listen" => "tls/127.0.0.1:#{port}", "ca" => "#{certs}/ca.pem",
                                        "certificate" => "#{certs}/%<name>s.pem", "private_key" => "#{certs}/%<name>s.key" },
                               roles: [ CALLER ]).to_h
    if without_deny
      h["access_control"]["policies"].each { _1["rules"].delete("no_rshell_calls") }
      h["access_control"]["rules"].reject! { _1["id"] == "no_rshell_calls" }
    end
    file = File.join(@dir, "router.json")
    File.write(file, JSON.generate(h))
    incs = %w[asterism asterism-zenoh].flat_map { |g| Gem.loaded_specs.fetch(g).full_require_paths.flat_map { [ "-I", _1 ] } }
    @router = IO.popen([ RbConfig.ruby, *incs, "-e", ROUTER, file ], "r+")
    assert_equal "ready", @router.gets&.strip
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

  def machine_and_callers(loc)
    machine = connect(loc, "fmruby-aaaaaa", "transfer")
    inbox = Object.new
    def inbox.ping = "pong"
    machine.expose("inbox", inbox, methods: { ping: 0 })
    machine.expose("rshell", FakeRShell.new("fmruby-aaaaaa", allow: %w[console pc]), methods: FakeRShell::METHODS,
                                                                                     caller: :from)
    machine.start
    console = connect(loc, "console", "console")
    console.start
    pc = connect(loc, "pc", "probe")
    pc.start
    sleep 1.0 # the declarations travel
    [ console, pc ]
  end

  test "the console opens a machine's remote shell; another member, whose role calls anything, does not" do
    console, pc = machine_and_callers(router)
    a = console["fmruby-aaaaaa/transfer/rshell", timeout: 5].asterism_call("open")
    assert_equal [ 1, "/home" ], a.values_at("id", "cwd")
    assert_equal "pong", pc["fmruby-aaaaaa/transfer/inbox", timeout: 5].ping, "the member's calls reach the machine"
    assert_raises(Asterism::TimeoutError, "but not its remote shell") do
      pc["fmruby-aaaaaa/transfer/rshell", timeout: 3].asterism_call("open")
    end
  end

  test "without the deny the same member would get in (the machine lets it)" do
    _console, pc = machine_and_callers(router(without_deny: true))
    assert_equal 1, pc["fmruby-aaaaaa/transfer/rshell", timeout: 5].asterism_call("open")["id"]
  end
end
