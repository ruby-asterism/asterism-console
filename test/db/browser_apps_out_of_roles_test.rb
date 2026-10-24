require "test_helper"
require Rails.root.join("db/migrate/20261024100000_browser_apps_out_of_roles").to_s

# 0.3.12 (db/migrate/*_browser_apps_out_of_roles.rb): the roles' browser
# apps are copied to the Studio apps before the column goes; the roles and
# their rows stay as they were.
class BrowserAppsMigrationTest < ActiveSupport::TestCase
  # The test's transaction takes the schema changes back too (SQLite).
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { BrowserAppsOutOfRoles.new.migrate(direction) }
  ensure
    [ RelayRole, BrowserApp, BrowserAppsOutOfRoles::Role, BrowserAppsOutOfRoles::App ].each(&:reset_column_information)
  end

  teardown do
    [ RelayRole, BrowserApp, BrowserAppsOutOfRoles::Role, BrowserAppsOutOfRoles::App ].each(&:reset_column_information)
  end

  test "the roles' apps become the list, each once, then the column goes" do
    migrate(:down)
    c = ActiveRecord::Base.connection
    assert c.column_exists?(:relay_roles, :browser_app)
    refute c.table_exists?(:browser_apps)
    RelayPeerRole.delete_all
    RelayRole.delete_all
    roles = { "match" => [ "/app/test/othello.app.rb", true ], "board" => [ "/app/game/mahjong/mahjong.app.rb", false ],
              "games" => [ " /app/game/mahjong/mahjong.app.rb", true ], "viewer" => [ "", false ], "spectator" => [ nil, false ] }
    roles.each do |name, (app, browsers)|
      c.execute("INSERT INTO relay_roles (name, browser_app, for_browsers, created_at, updated_at) VALUES " \
                "(#{c.quote(name)}, #{c.quote(app)}, #{c.quote(browsers)}, datetime(), datetime())")
    end
    peer = RelayPeer.create!(name: "home-a", kind: "router")
    RelayRole.find_each { RelayPeerRole.create!(relay_peer: peer, relay_role: _1) }

    migrate(:up)
    refute c.column_exists?(:relay_roles, :browser_app)
    assert_equal [ [ "games", "/app/game/mahjong/mahjong.app.rb" ], [ "match", "/app/test/othello.app.rb" ] ],
                 BrowserApp.in_order.map { [ _1.label, _1.path ] }, "a role for the browsers names a shared app"
    assert_equal %w[board games match spectator viewer], RelayRole.order(:name).pluck(:name)
    assert_equal %w[games match], RelayRole.where(for_browsers: true).order(:name).pluck(:name)
    assert_equal 5, peer.reload.roles.count, "the rows keep their roles (SQLite copies the table)"
    assert_equal [ "/app/game/mahjong/mahjong.app.rb", "/app/test/othello.app.rb" ], BrowserPage.apps.drop(1).map(&:last)

    migrate(:down)
    assert_equal({ "games" => "/app/game/mahjong/mahjong.app.rb", "match" => "/app/test/othello.app.rb" },
                 c.select_rows("SELECT name, browser_app FROM relay_roles WHERE browser_app IS NOT NULL").to_h)
  end
end
