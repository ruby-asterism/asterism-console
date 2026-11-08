require "test_helper"

# Who a member row's machines receive files from (0.3.16, T6): the form's
# picks and lines make the lists, the time they changed, what the bridge
# sends, and the choices the form offers.
class RelayPeerReceiversTest < ActiveSupport::TestCase
  setup { RelayPeer.delete_all }

  test "picks and other lines make a kind's list; a change marks the time, the same list does not" do
    tab5 = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client")
    refute tab5.managed_receivers?
    assert_equal [ [], [] ], [ tab5.receivers("file"), tab5.receivers("checkpoint") ]
    tab5.update!(receive_files_from_picked: [ "fmruby-bbbbbb", "" ], receive_files_from_more: "fmruby-*\nfmruby-bbbbbb\n",
                 receive_checkpoints_from_picked: [ "" ], receive_checkpoints_from_more: "")
    assert_equal %w[fmruby-bbbbbb fmruby-*], tab5.receivers("file")
    assert_equal [], tab5.receivers("checkpoint")
    at = tab5.receivers_changed_at
    assert at
    assert tab5.receives_any?
    travel 1.minute do
      tab5.update!(receive_files_from_picked: [ "fmruby-bbbbbb" ], receive_files_from_more: "fmruby-*", description: "x")
      assert_equal at, tab5.reload.receivers_changed_at, "the same list is no change"
      tab5.update!(receive_files_from_picked: [], receive_files_from_more: "")
      assert_operator tab5.reload.receivers_changed_at, :>, at
      assert tab5.managed_receivers?, "an emptied list is still managed (it is sent)"
      refute tab5.receives_any?
    end
    assert_equal({ "file" => [], "checkpoint" => [], "at" => tab5.receivers_changed_at.utc.iso8601 }, tab5.receivers_payload)
  end

  test "a line that is not a node ID or a pattern is not saved" do
    p = RelayPeer.new(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: "ok-1\nbad name\nasterism/**")
    refute p.save
    assert_match(/not node IDs or patterns: bad name asterism\/\*\*/, p.errors.full_messages.join)
    p = RelayPeer.new(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: (1..65).map { "n#{_1}" }.join("\n"))
    refute p.save
  end

  test "the digest follows the lists and the time; the bridge's record is read back" do
    p = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: "linux-1")
    d1 = p.receivers_digest
    p.update!(receive_checkpoints_from_more: "linux-1")
    refute_equal d1, p.receivers_digest
    p.update_column(:receivers_delivered, '{"fmruby-aaaaaa":{"digest":"x","at":"2026-11-09T00:00:00Z"}}')
    assert_equal "x", p.reload.delivered["fmruby-aaaaaa"]["digest"]
    p.update_column(:receivers_delivered, "not json")
    assert_equal({}, p.reload.delivered)
  end

  test "the form offers the rows' nodes and the console, not a client row's own node" do
    home = RelayPeer.create!(name: "home-a", kind: "router", nodes: "fmruby-bbbbbb\nlinux-1")
    tab5 = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", display_name: "Tab5")
    assert_equal %w[console fmruby-bbbbbb linux-1], RelayPeer.sender_choices(except: tab5).map(&:last)
    assert_equal %w[console fmruby-aaaaaa fmruby-bbbbbb linux-1], RelayPeer.sender_choices(except: home).map(&:last),
                 "the nodes behind one home router may send to each other"
    assert_equal [ "Tab5 (fmruby-aaaaaa)", "fmruby-aaaaaa" ],
                 RelayPeer.sender_choices(except: RelayPeer.find_by!(name: "home-a")).find { _1[1] == "fmruby-aaaaaa" }
  end

  test "the bridge's rows: enabled ones whose lists were chosen" do
    a = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client", receive_files_from_more: "linux-1")
    RelayPeer.create!(name: "fmruby-bbbbbb", kind: "client")
    RelayPeer.create!(name: "fmruby-cccccc", kind: "client", receive_files_from_more: "linux-1", enabled: false)
    assert_equal [ a ], RelayPeer.managed.to_a
  end
end
