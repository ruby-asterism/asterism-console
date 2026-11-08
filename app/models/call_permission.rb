# One combination the page may call: <node>/<app>/<object> and a method,
# each a pattern in which * matches any run of characters (within that
# part). Nothing else can be called: with no rows, every call is refused.
# Only admins edit them (CallPermissionsController).
#
#   node "fmruby-*", app "demo", object "screen", method "say"
#   node "cruby",    app "demo", object "*",      method "status"
#
# A row of kind "file" (T4, docs/files.md) says instead that the page may
# send files to the nodes its node pattern matches (the console's bridge
# sends to <node>/transfer/inbox; the machine takes them only when its
# receive.toml lets the console in, [file] from). Its app, object and
# method are "transfer", "inbox" and "*" and allow no call: the call rows
# and the file rows never stand in for each other.
class CallPermission < ApplicationRecord
  PART = /\A[A-Za-z0-9_.*-]{1,64}\z/
  METHOD = /\A[A-Za-z0-9_*]{1,64}[?!]?\z/
  KINDS = %w[call file].freeze
  FILE_PATH = %w[transfer inbox *].freeze

  belongs_to :created_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :node, :app, :object, format: { with: PART, message: "may hold letters, digits, _ . - and *" }
  validates :method_name, format: { with: METHOD, message: "may hold letters, digits, _ and *, then ? or !" }

  scope :calls, -> { where(kind: "call") }
  scope :files, -> { where(kind: "file") }

  before_validation { self.app, self.object, self.method_name = FILE_PATH if kind == "file" }

  # Whether some row allows calling method on path (<node>/<app>/<object>).
  # Without a method: whether some row covers the object at all (reading
  # its meta, the list of exposed methods). Only the rows of kind "call".
  def self.allows?(path, method = nil, rows: all)
    node, app, object = path.to_s.split("/", 3)
    return false if object.nil?
    rows.any? { |r| r.call? && r.covers?(node, app, object) && (method.nil? || match?(r.method_name, method)) }
  end

  # Whether some row of kind "file" lets the page send files to node.
  def self.allows_file?(node, rows: all)
    rows.any? { |r| r.kind == "file" && match?(r.node, node.to_s) }
  end

  # The rows that cover path (for the page: which methods may be called).
  def self.for_path(path, rows: all)
    node, app, object = path.to_s.split("/", 3)
    return [] if object.nil?
    rows.select { |r| r.call? && r.covers?(node, app, object) }
  end

  def call? = kind != "file"

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
    { "id" => id, "kind" => kind, "node" => node, "app" => app, "object" => object, "method" => method_name, "note" => note }
  end
end
