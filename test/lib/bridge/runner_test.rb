require "test_helper"
require "asterism"

# How the bridge runs a request and what it writes back, with a stand-in
# for the object layer (no network).
class Bridge::RunnerTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  class Objects
    attr_reader :calls

    def initialize
      @calls = []
    end

    def meta(path, timeout_ms)
      @calls << [ :meta, path, timeout_ms ]
      { "methods" => [ [ "say", -1 ], [ "status", 0 ] ] }
    end

    def call(path, name, args, kwargs, timeout_ms)
      @calls << [ :call, path, name, args, kwargs, timeout_ms ]
      case name
      when "say" then args[0].to_s.length
      when "status" then { "name" => "fmruby-aaaaaa", "up_ms" => 5 }
      when "secret" then raise Asterism::RemoteError.new("NoMethodError", "undefined method 'secret' (not exposed)")
      when "slow" then raise Asterism::Timeout, "no answer within #{timeout_ms} ms"
      when "gone" then raise Asterism::Disconnected, "the connection was lost"
      end
    end
  end

  setup do
    CallPermission.create!(node: "*", app: "*", object: "*", method_name: "*")
    @objects = Objects.new
    @runner = Bridge::Runner.new(objects: @objects, logger: Logger.new(nil))
    @runner.define_singleton_method(:say) { |_text| nil }
  end

  def run_request(**attrs)
    req = BridgeRequest.create!({ kind: "call", path: "fmruby-aaaaaa/demo/screen", timeout_s: 2.5 }.merge(attrs))
    assert_broadcasts(ConsoleChannel::STREAM, 1) { @runner.send(:perform, req) }
    req.reload
  end

  test "a call that answers" do
    r = run_request(method_name: "say", args: '["hello"]', kwargs: '{"tag":"x"}')
    assert_equal "ok", r.status
    assert_equal 5, r.result_value
    assert r.took_ms >= 0
    assert r.finished_at
    assert_equal [ :call, "fmruby-aaaaaa/demo/screen", "say", [ "hello" ], { tag: "x" }, 2500 ], @objects.calls.last
  end

  test "a Hash comes back as JSON" do
    assert_equal({ "name" => "fmruby-aaaaaa", "up_ms" => 5 }, run_request(method_name: "status").result_value)
  end

  test "meta" do
    r = run_request(kind: "meta")
    assert_equal({ "methods" => [ [ "say", -1 ], [ "status", 0 ] ] }, r.result_value)
  end

  test "RemoteError, Timeout and a lost connection" do
    r = run_request(method_name: "secret")
    assert_equal [ "remote_error", "NoMethodError" ], [ r.status, r.error_class ]
    assert_match(/not exposed/, r.error_message)
    r = run_request(method_name: "slow")
    assert_equal "timeout", r.status
    assert_match(/2500 ms/, r.error_message)
    r = run_request(method_name: "gone")
    assert_equal [ "error", "Asterism::Disconnected" ], [ r.status, r.error_class ]
  end

  test "the bridge checks the call permissions again" do
    CallPermission.delete_all
    CallPermission.create!(node: "fmruby-*", app: "demo", object: "screen", method_name: "say")
    r = run_request(method_name: "say", args: '["x"]')
    assert_equal "ok", r.status
    r = run_request(method_name: "status") # written by hand, past the page
    assert_equal [ "denied", "NotPermitted" ], [ r.status, r.error_class ]
    assert_match(/checked by the bridge/, r.error_message)
    assert_equal 1, @objects.calls.size
  end

  test "requests nobody picked up expire" do
    old = BridgeRequest.create!(kind: "meta", path: "a/b/c", created_at: 1.minute.ago)
    fresh = BridgeRequest.create!(kind: "meta", path: "a/b/c")
    @runner.send(:expire_requests)
    assert_equal "expired", old.reload.status
    assert_equal "pending", fresh.reload.status
  end

  test "the zenoh configuration from the environment: none, TLS, mutual TLS, a file" do
    assert_nil Bridge::Runner.zenoh_config({})
    assert_equal({ "transport/link/tls/root_ca_certificate" => "/c/ca.pem" },
                 Bridge::Runner.zenoh_config("ASTERISM_TLS_CA" => "/c/ca.pem"))
    cfg = Bridge::Runner.zenoh_config("ASTERISM_TLS_CA" => "/c/ca.pem", "ASTERISM_TLS_CERT" => "/c/console.pem",
                                      "ASTERISM_TLS_KEY" => "/c/console.key")
    assert_equal "/c/console.pem", cfg["transport/link/tls/connect_certificate"]
    assert_equal "/c/console.key", cfg["transport/link/tls/connect_private_key"]
    assert_equal true, cfg["transport/link/tls/enable_mtls"]
    assert_raises(KeyError) { Bridge::Runner.zenoh_config("ASTERISM_TLS_CERT" => "/c/console.pem") }
    Tempfile.create([ "zenoh", ".json5" ]) do |f|
      f.write("{ mode: 'client' }")
      f.flush
      assert_equal "{ mode: 'client' }", Bridge::Runner.zenoh_config("ASTERISM_ZENOH_CONFIG" => f.path)
    end
  end
end
