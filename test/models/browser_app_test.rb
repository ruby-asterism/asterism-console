require "test_helper"

# The Studio apps (0.3.12): a path in the characters a URL fragment carries,
# each once, listed by position, then label, then path.
class BrowserAppTest < ActiveSupport::TestCase
  test "a path like the roles' browser app was, each once" do
    assert BrowserApp.new(path: " /app/game/board/board.app.rb ").tap(&:validate).then { _1.errors.empty? && _1.path == "/app/game/board/board.app.rb" }
    refute BrowserApp.new(path: "").valid?
    refute BrowserApp.new(path: "/app/a b.rb").valid?
    refute BrowserApp.new(path: "/app/x.rb#y").valid?
    refute BrowserApp.new(path: "x" * 201).valid?
    refute BrowserApp.new(path: "/app/test/othello.app.rb").valid?, "the fixture has it"
    refute BrowserApp.new(path: "/app/y.rb", position: 1.5).valid?
    assert_nil BrowserApp.create!(path: "/app/y.rb", label: "  ").label
  end

  test "the menus' order: position first (those without last), then by label, then the unlabelled by path" do
    BrowserApp.create!(path: "/app/z.rb")
    BrowserApp.create!(path: "/app/b.rb", label: "Board")
    BrowserApp.create!(path: "/app/m.rb", label: "Mahjong", position: 2)
    BrowserApp.create!(path: "/app/c.rb", label: "Chess", position: 1)
    assert_equal %w[/app/c.rb /app/m.rb /app/b.rb /app/test/othello.app.rb /app/z.rb], BrowserApp.in_order.map(&:path)
    assert_equal [ "Chess (/app/c.rb)", "/app/c.rb" ], BrowserApp.find_by!(path: "/app/c.rb").option
    assert_equal [ "/app/z.rb", "/app/z.rb" ], BrowserApp.find_by!(path: "/app/z.rb").option
  end

  test "Make a pass and the rooms offer them" do
    assert_equal [ [ "Nothing (the page's own start)", "" ], [ "Othello (/app/test/othello.app.rb)", "/app/test/othello.app.rb" ] ],
                 BrowserPage.apps
    assert_equal [ [ "Othello (/app/test/othello.app.rb)", "/app/test/othello.app.rb" ] ],
                 RoomPage.apps({ "ASTERISM_ROOM_APPS" => "" })
    assert_equal [ [ "Othello (/app/test/othello.app.rb)", "/app/test/othello.app.rb" ] ],
                 RoomPage.apps({ "ASTERISM_ROOM_APPS" => "Othello=/app/test/othello.app.rb" }), "each path once"
  end
end
