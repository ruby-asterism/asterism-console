require "test_helper"
require "open3"
require "socket"
require "tmpdir"
require "exposure_check"

# The exposure check (lib/exposure_check.rb, bin/asterism-exposure) against
# a tiny HTTP server on the loopback and a port nobody listens on. Nothing
# leaves the machine.
class ExposureCheckTest < ActiveSupport::TestCase
  HOST = "127.0.0.1".freeze
  BIN = Rails.root.join("bin/asterism-exposure").to_s

  setup do
    @server = TCPServer.new(HOST, 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
    closed = TCPServer.new(HOST, 0)
    @closed_port = closed.addr[1]
    closed.close
    @tmp = Dir.mktmpdir("exposure")
  end

  teardown do
    @thread.kill
    @server.close
    FileUtils.rm_rf(@tmp)
  end

  def routes
    {
      "/invite" => [ 200, {}, %(<link rel="stylesheet" href="/assets/application-0a1b2c3d.css" data-turbo-track="reload">\n<p>Make a room</p>) ],
      "/assets/application-0a1b2c3d.css" => [ 200, {}, "body{}" ],
      "/plain" => [ 200, {}, "<p>no assets here</p>" ],
      "/broken" => [ 200, {}, %(<script src="/assets/missing-99.js"></script>) ],
      "/" => [ 403, {}, "forbidden" ],
      "/old" => [ 302, { "Location" => "http://#{HOST}:#{@port}/new" }, "" ]
    }
  end

  def serve
    loop do
      client = @server.accept
      request = client.readpartial(4096) # a request's head fits; a TLS hello gets a plain answer
      path = request.start_with?("GET ") ? request.split[1].to_s : "(not http)"
      status, headers, body = routes.fetch(path, [ 404, {}, "not found" ])
      head = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      client.write("HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n#{head}\r\n#{body}")
      client.close
    rescue IOError, SystemCallError
      next
    end
  end

  def run_checks(checks, connector: nil)
    config = { "scheme" => "http", "port" => @port, "timeout" => 2, "checks" => checks }
    ExposureCheck.run(config, { "default" => HOST }, connector: connector)
  end

  def one(check, connector = nil) = run_checks([ check ], connector: connector).first

  test "http: the status is compared with one code or a list" do
    assert one("http" => "/invite", "status" => 200).ok
    assert one("http" => "/", "status" => [ 403, 404 ]).ok
    r = one("http" => "/", "status" => 200)
    refute r.ok
    assert_equal "403", r.actual
    assert_equal "200", r.expected
  end

  test "http: the body must contain the text when one is given" do
    assert one("http" => "/invite", "status" => 200, "body" => "Make a room").ok
    r = one("http" => "/invite", "status" => 200, "body" => "Sign in")
    refute r.ok
    assert_match(/body lacks/, r.actual)
  end

  test "http: a redirect is not followed, its target shown without the host" do
    assert one("http" => "/old", "status" => 302).ok
    r = one("http" => "/old", "status" => 403)
    refute r.ok
    assert_equal "302 -> http://<host>/new", r.actual
    refute_includes r.line, HOST
  end

  test "asset_from picks an /assets/ file from the page and checks it" do
    r = one("asset_from" => "/invite")
    assert r.ok, r.line
    assert_includes r.target, "/assets/application-0a1b2c3d.css"
    r = one("asset_from" => "/plain")
    refute r.ok
    assert_match(/no \/assets/, r.actual)
    r = one("asset_from" => "/broken")
    refute r.ok
    assert_equal "404", r.actual
    r = one("asset_from" => "/nowhere")
    refute r.ok
    assert_equal "page answered 404", r.actual
  end

  test "the asset's path in a page" do
    assert_equal "/assets/app-1f.css", ExposureCheck.asset_path(%(<link href="/assets/app-1f.css">))
    assert_equal "/assets/controllers/x-2e.js", ExposureCheck.asset_path(%(<script src='/assets/controllers/x-2e.js'></script>))
    assert_equal "/assets/a.js", ExposureCheck.asset_path(%("https://cdn.example.org/assets/a.js?v=1"))
    assert_nil ExposureCheck.asset_path(%(<img src="/assets/logo.png">))
    assert_nil ExposureCheck.asset_path(nil)
  end

  test "tcp: open and closed (a refusal)" do
    assert one("tcp" => @port, "expect" => "open").ok
    r = one("tcp" => @port, "expect" => "closed")
    refute r.ok
    assert_equal "open", r.actual
    r = one("tcp" => @closed_port, "expect" => "closed")
    assert r.ok
    assert_equal "refused", r.actual
    r = one("tcp" => @closed_port, "expect" => "open")
    refute r.ok
    assert_equal "<host>:#{@closed_port}", r.target
  end

  test "tcp: a timeout passes as closed and fails as open" do
    [ Errno::ETIMEDOUT, IO::TimeoutError ].each do |error|
      timing_out = ->(_host, _port, _timeout) { raise error }
      r = one({ "tcp" => 7448, "expect" => "closed" }, timing_out)
      assert r.ok, error.name
      assert_equal "timeout", r.actual
      refute one({ "tcp" => 7448, "expect" => "open" }, timing_out).ok
    end
    unresolved = ->(*) { raise SocketError, "getaddrinfo: Name or service not known" }
    r = one({ "tcp" => 7448, "expect" => "closed" }, unresolved)
    refute r.ok, "a name that does not resolve says nothing about the port"
    assert_equal "name not resolved", r.actual
  end

  test "tcp: the timeout reaches the connection" do
    seen = nil
    one({ "tcp" => 7443, "timeout" => 3 }, ->(_h, _p, t) { seen = t })
    assert_equal 3.0, seen
  end

  test "a refused connection and a TLS failure fail the check, nothing raises" do
    config = { "scheme" => "http", "port" => @closed_port, "checks" => [ { "http" => "/", "status" => 403 } ] }
    r = ExposureCheck.run(config, { "default" => HOST }).first
    refute r.ok
    assert_equal "refused", r.actual
    r = one("http" => "/", "status" => 403, "scheme" => "https")
    refute r.ok
    assert_match(/\Atls error/, r.actual)
    refute_includes r.line, HOST
  end

  test "host names and addresses are cut out of messages" do
    secrets = ExposureCheck.scrub_list([ "asterism.example.org", HOST ])
    text = "Failed to open TCP connection to asterism.example.org:443 (connect(2) for 127.0.0.1:443)"
    assert_equal "Failed to open TCP connection to <host>:443 (connect(2) for <host>:443)",
                 ExposureCheck.scrub(text, secrets)
  end

  test "the hosts come from the environment and --host" do
    env = { "ASTERISM_EXPOSURE_HOST" => "asterism.example.org", "ASTERISM_EXPOSURE_HOST_ROUTER" => "router.example.org",
            "ASTERISM_EXPOSURE_HOST_EMPTY" => "", "PATH" => "/bin" }
    assert_equal({ "default" => "asterism.example.org", "router" => "router.example.org" }, ExposureCheck.hosts_from(env))
    assert_equal({ "default" => "192.0.2.1", "router" => "192.0.2.2" },
                 ExposureCheck.hosts_from({}, [ "192.0.2.1", "router=192.0.2.2" ]))
  end

  test "a check with an unknown host stops before any check runs" do
    connected = false
    error = assert_raises(ExposureCheck::ConfigError) do
      run_checks([ { "tcp" => 1, "expect" => "open" }, { "tcp" => 2, "host" => "router" } ],
                 connector: ->(*) { connected = true })
    end
    assert_match(/ASTERISM_EXPOSURE_HOST_ROUTER/, error.message)
    refute connected
  end

  def write_config(checks)
    path = File.join(@tmp, "checks.yml")
    File.write(path, { "scheme" => "http", "port" => @port, "timeout" => 2, "checks" => checks }.to_yaml)
    path
  end

  # bin/asterism-exposure as a CI job runs it: a bare ruby, no bundle.
  def run_bin(*args, host: HOST)
    Bundler.with_unbundled_env do
      Open3.capture2e({ "ASTERISM_EXPOSURE_HOST" => host, "RUBYOPT" => nil }, RbConfig.ruby, BIN, *args)
    end
  end

  test "the command: exit 0 when all pass, 1 when one fails, no host in the output" do
    ok = write_config([ { "http" => "/invite", "status" => 200 }, { "asset_from" => "/invite" },
                        { "http" => "/", "status" => 403 }, { "tcp" => @closed_port, "expect" => "closed" } ])
    out, status = run_bin(ok)
    assert_equal 0, status.exitstatus, out
    assert_includes out, "4 passed, 0 failed"
    refute_includes out, HOST

    bad = write_config([ { "http" => "/", "status" => 200 }, { "http" => "/old", "status" => 403 },
                         { "tcp" => @closed_port, "expect" => "open" } ])
    out, status = run_bin(bad)
    assert_equal 1, status.exitstatus, out
    assert_includes out, "0 passed, 3 failed"
    assert_equal 3, out.lines.count { _1.start_with?("FAIL") }
    refute_includes out, HOST
  end

  test "the command: exit 2 without a host or with a bad file" do
    path = write_config([ { "http" => "/", "status" => 403 } ])
    out, status = run_bin(path, host: "")
    assert_equal 2, status.exitstatus
    assert_match(/no host "default"/, out)
    File.write(path, "checks: [")
    out, status = run_bin(path)
    assert_equal 2, status.exitstatus, out
  end
end
