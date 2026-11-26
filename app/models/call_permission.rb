# One combination the page may call: <node>/<app>/<object> and a method,
# each a pattern in which * matches any run of characters (within that
# part). Nothing else can be called: with no rows, every call is refused.
# Only admins edit them (CallPermissionsController).
#
#   node "fmruby-*", app "demo", object "screen", method "say"
#   node "cruby",    app "demo", object "*",      method "status"
#
# Which nodes the page may send files to is not here: since 0.3.14 (T4b,
# docs/files.md) it is a mark of the member's row (Admin > Members,
# RelayPeer#files_from_console). 0.3.13's rows of kind "file" moved there.
#
# A machine's remote shell (<node>/transfer/rshell, docs/terminal.md) is
# never covered, whatever a row says: only the Terminal's remote shell
# calls it, with the users' own permissions (User#rshell_access).
class CallPermission < ApplicationRecord
  PART = /\A[A-Za-z0-9_.*-]{1,64}\z/
  METHOD = /\A[A-Za-z0-9_*]{1,64}[?!]?\z/

  belongs_to :created_by, class_name: "User", optional: true

  validates :node, :app, :object, format: { with: PART, message: "may hold letters, digits, _ . - and *" }
  validates :method_name, format: { with: METHOD, message: "may hold letters, digits, _ and *, then ? or !" }

  # Whether some row allows calling method on path (<node>/<app>/<object>).
  # Without a method: whether some row covers the object at all (reading
  # its meta, the list of exposed methods).
  def self.allows?(path, method = nil, rows: all)
    node, app, object = path.to_s.split("/", 3)
    return false if object.nil? || reserved?(app, object)
    rows.any? { |r| r.covers?(node, app, object) && (method.nil? || match?(r.method_name, method)) }
  end

  # The rows that cover path (for the page: which methods may be called).
  def self.for_path(path, rows: all)
    node, app, object = path.to_s.split("/", 3)
    return [] if object.nil? || reserved?(app, object)
    rows.select { |r| r.covers?(node, app, object) }
  end

  # The objects no row covers: the machines' remote shells.
  def self.reserved?(app, object)
    app.to_s == "transfer" && object.to_s == "rshell"
  end

  # Why path is never called through a permission (nil: it may be).
  def self.reserved_reason(path)
    _node, app, object = path.to_s.split("/", 3)
    return nil unless reserved?(app, object)
    "#{path} is a machine's remote shell: only the Terminal's remote <node> calls it (with the user's remote " \
      "shell permission, under Users), never a call permission"
  end

  def self.match?(pattern, value)
    Regexp.new("\\A#{Regexp.escape(pattern.to_s).gsub('\\*', '[^/]*')}\\z").match?(value.to_s)
  end

  def covers?(n, a, o)
    self.class.match?(node, n) && self.class.match?(app, a) && self.class.match?(object, o)
  end

  def path_pattern
    "#{node}/#{app}/#{object}"
  end

  def as_payload
    { "id" => id, "node" => node, "app" => app, "object" => object, "method" => method_name, "note" => note }
  end
end
