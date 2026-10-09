# One combination the page may call: <node>/<app>/<object> and a method,
# each a pattern in which * matches any run of characters (within that
# part). Nothing else can be called: with no rows, every call is refused.
# Only admins edit them (CallPermissionsController).
#
#   node "fmruby-*", app "demo", object "screen", method "say"
#   node "cruby",    app "demo", object "*",      method "status"
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
    return false if object.nil?
    rows.any? { |r| r.covers?(node, app, object) && (method.nil? || match?(r.method_name, method)) }
  end

  # The rows that cover path (for the page: which methods may be called).
  def self.for_path(path, rows: all)
    node, app, object = path.to_s.split("/", 3)
    return [] if object.nil?
    rows.select { |r| r.covers?(node, app, object) }
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
