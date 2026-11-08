require "test_helper"
require Rails.root.join("db/migrate/20261108200000_member_file_marks").to_s

# 0.3.14 (db/migrate/*_member_file_marks.rb, T4b): 0.3.13's call
# permissions of kind "file" and ASTERISM_TRANSFER_FROM become the members'
# marks; what matches no member is said, and the file rows and the column
# kind go. The call rows stay.
class MemberFileMarksMigrationTest < ActiveSupport::TestCase
  MODELS = [ RelayPeer, CallPermission, MemberFileMarks::Peer, MemberFileMarks::Permission ].freeze

  def migrate(direction)
    out = StringIO.new
    old = $stdout
    $stdout = out
    MemberFileMarks.new.migrate(direction)
    out.string
  ensure
    $stdout = old
    MODELS.each(&:reset_column_information)
  end

  teardown { MODELS.each(&:reset_column_information) }

  def with_env(value)
    old = ENV["ASTERISM_TRANSFER_FROM"]
    ENV["ASTERISM_TRANSFER_FROM"] = value
    yield
  ensure
    ENV["ASTERISM_TRANSFER_FROM"] = old
  end

  test "the file rows and the setting mark the members that speak for a node they match" do
    migrate(:down)
    c = ActiveRecord::Base.connection
    assert c.column_exists?(:call_permissions, :kind)
    refute c.column_exists?(:relay_peers, :files_to_console)
    CallPermission.delete_all
    RelayPeer.delete_all
    tab5 = RelayPeer.create!(name: "fmruby-aaaaaa", kind: "client")
    home = RelayPeer.create!(name: "home-a", kind: "router", nodes: "fmruby-bbbbbb\nlinux-1")
    cruby = RelayPeer.create!(name: "cruby", kind: "client")
    rows = [ %w[call fmruby-* demo screen say], %w[file fmruby-* transfer inbox *], %w[file wasm-* transfer inbox *],
             %w[file cruby transfer inbox *] ]
    rows.each do |kind, node, app, object, m|
      c.execute("INSERT INTO call_permissions (kind, node, app, object, method_name, created_at, updated_at) VALUES " \
                "(#{[ kind, node, app, object, m ].map { c.quote(_1) }.join(', ')}, datetime(), datetime())")
    end

    out = with_env("linux-*, nobody-*") { migrate(:up) }
    refute c.column_exists?(:call_permissions, :kind)
    assert_equal [ %w[fmruby-* demo screen say] ], CallPermission.pluck(:node, :app, :object, :method_name),
                 "the call row stays, the file rows go"
    marks = RelayPeer.order(:name).to_h { [ _1.name, [ _1.files_to_console?, _1.files_from_console? ] ] }
    assert_equal({ "cruby" => [ false, true ], "fmruby-aaaaaa" => [ false, true ], "home-a" => [ true, true ] }, marks)
    assert_match(/"Allow sending files" fmruby-\*: marked files_from_console on fmruby-aaaaaa, home-a/, out)
    assert_match(/"Allow sending files" wasm-\*: no member row speaks for a node it matches; nothing marked/, out)
    assert_match(/ASTERISM_TRANSFER_FROM linux-\*: marked files_to_console on home-a/, out)
    assert_match(/ASTERISM_TRANSFER_FROM nobody-\*: no member row/, out)
    assert_equal [ tab5, home, cruby ].map(&:id).sort, RelayPeer.pluck(:id).sort

    # and back: a file row per node of a member that receives
    migrate(:down)
    assert_equal [ %w[file cruby], %w[file fmruby-aaaaaa], %w[file fmruby-bbbbbb], %w[file linux-1] ],
                 c.select_rows("SELECT kind, node FROM call_permissions WHERE kind = 'file' ORDER BY node")
    migrate(:up)
  end

  test "nothing to move: nothing said, nothing marked" do
    migrate(:down)
    out = with_env(nil) { migrate(:up) }
    refute_match(/marked|nothing marked/, out)
    assert_equal 0, RelayPeer.where(files_to_console: true).or(RelayPeer.where(files_from_console: true)).count
  end
end
