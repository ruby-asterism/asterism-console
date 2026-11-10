require "test_helper"
require "asterism"

# The bridge sends each member machine its senders' list (Bridge::Receivers,
# T6): when the list changed, when the machine's transfer app appears, every
# AGAIN_EVERY, again after a failure. A stand-in takes the calls.
class Bridge::ReceiversTest < ActiveSupport::TestCase
  setup do
    RelayPeer.delete_all
    @calls = []
    @fail = nil
    @receiving = nil
    @said = []
    @r = Bridge::Receivers.new(say: ->(t) { @said << t }, call: lambda { |node, payload|
      @calls << [ node, payload ]
      raise Asterism::RemoteError.new("ArgumentError", @fail, "raised") if @fail
      answer = { "ok" => true, "written" => true, "at" => payload["at"] }
      answer["receiving"] = @receiving unless @receiving.nil?
      answer
    }).start
  end

  teardown { @r.close }

  def sync(apps, now)
    @r.sync(apps, now: now)
    @r.drain
  end

  test "sent when the machine is there, again when the list changes, and when it comes back" do
    home = RelayPeer.create!(name: "home-a", kind: "router", nodes: "fmruby-aaaaaa\nfmruby-bbbbbb",
                             receive_files_from_more: "linux-*")
    RelayPeer.create!(name: "fmruby-zzzzzz", kind: "client") # never chosen: never sent
    sync(%w[fmruby-aaaaaa/transfer fmruby-aaaaaa/shell fmruby-zzzzzz/transfer], 100.0)
    assert_equal [ [ "fmruby-aaaaaa", { "file" => [ "linux-*" ], "checkpoint" => [], "at" => home.receivers_changed_at.utc.iso8601 } ] ],
                 @calls
    got = home.reload.delivered
    assert_equal [ "fmruby-aaaaaa" ], got.keys
    assert_equal home.receivers_digest, got["fmruby-aaaaaa"]["digest"]
    assert(@said.any? { _1.include?("fmruby-aaaaaa has the list of home-a (written there)") })
    sync(%w[fmruby-aaaaaa/transfer], 110.0)
    assert_equal 1, @calls.size, "the same list is not sent again soon"
    sync(%w[fmruby-aaaaaa/transfer], 110.0 + Bridge::Receivers::AGAIN_EVERY)
    assert_equal 2, @calls.size, "again after a while"
    travel 1.second do
      home.update!(receive_checkpoints_from_more: "fmruby-bbbbbb")
    end
    sync(%w[fmruby-aaaaaa/transfer fmruby-bbbbbb/transfer], 800.0)
    assert_equal %w[fmruby-aaaaaa fmruby-bbbbbb], @calls.last(2).map(&:first).sort, "a changed list, and a new machine"
    sync([], 801.0)
    sync(%w[fmruby-aaaaaa/transfer], 802.0)
    assert_equal "fmruby-aaaaaa", @calls.last[0], "it came back"
    assert_equal 5, @calls.size
  end

  test "a refusal is kept on the row and tried again later" do
    p = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: "fmruby-bbbbbb")
    @fail = "fmruby-aaaaaa takes no list from console over a connection without certificates (its router is not tls/)"
    sync(%w[fmruby-aaaaaa/transfer], 10.0)
    d = p.reload.delivered["fmruby-aaaaaa"]
    assert_match(/without certificates/, d["error"])
    assert_nil d["digest"]
    assert(@said.any? { _1.include?("not delivered") })
    sync(%w[fmruby-aaaaaa/transfer], 20.0)
    assert_equal 1, @calls.size
    @fail = nil
    sync(%w[fmruby-aaaaaa/transfer], 10.0 + Bridge::Receivers::RETRY_EVERY)
    assert_equal 2, @calls.size
    d = p.reload.delivered["fmruby-aaaaaa"]
    assert_nil d["error"]
    assert_equal p.receivers_digest, d["digest"]
  end

  test "a disabled row is not sent" do
    RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: "x", enabled: false)
    sync(%w[fmruby-aaaaaa/transfer], 1.0)
    assert_empty @calls
  end

  test "a machine whose receiving is off (T7): the list is kept, the row says it is off" do
    p = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: "fmruby-bbbbbb")
    @receiving = false
    sync(%w[fmruby-aaaaaa/transfer], 1.0)
    d = p.reload.delivered["fmruby-aaaaaa"]
    assert_equal p.receivers_digest, d["digest"]
    assert_equal false, d["receiving"]
    helper = Object.new.extend(RelayHelper, ActionView::Helpers::TagHelper, ActionView::Helpers::OutputSafetyHelper)
    def helper.when_text(_t) = "now"
    assert_match(/receiving is off there/, helper.receivers_delivery(p).to_s)
    @receiving = true
    sync(%w[fmruby-aaaaaa/transfer], 1.0 + Bridge::Receivers::AGAIN_EVERY)
    assert_equal true, p.reload.delivered["fmruby-aaaaaa"]["receiving"]
    assert_no_match(/receiving is off/, helper.receivers_delivery(p).to_s)
  end

  test "a user's browser with lists is sent them at its node (T8)" do
    user = users(:user)
    user.update!(receive_files_from_more: "fmruby-aaaaaa")
    users(:admin).update!(receive_files_from_more: "x") # no handle: no browser node, never sent
    sync(%w[wasm-pat/transfer wasm-pat_2/transfer], 10.0)
    assert_equal [ [ "wasm-pat", { "file" => [ "fmruby-aaaaaa" ], "checkpoint" => [], "at" => user.reload.receivers_changed_at.utc.iso8601 } ] ],
                 @calls
    assert_equal user.receivers_digest, user.reload.delivered.dig("wasm-pat", "digest")
    assert(@said.any? { _1.include?("wasm-pat has the list of its user (written there)") })
  end
end
