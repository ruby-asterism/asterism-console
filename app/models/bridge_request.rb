# Something the page asks the bridge to do on the network: read an
# object's meta, or call one of its methods. Puma writes the row, the
# bridge (bin/bridge) picks it up, runs it and writes the answer back,
# then tells the page over Action Cable.
class BridgeRequest < ApplicationRecord
  KINDS = %w[meta call].freeze
  STATUSES = %w[pending running ok remote_error timeout error expired].freeze
  MAX_TIMEOUT = 30.0
  # A request the bridge has not picked up within this time is dropped.
  EXPIRE_AFTER = 30.seconds
  # <node>/<app>/<object>: no wildcards, no empty parts, nothing starting with @.
  PATH = %r{\A[^/*$?#@\s][^/*$?#\s]*/[^/*$?#@\s][^/*$?#\s]*/[^/*$?#@\s][^/*$?#\s]*\z}
  METHOD = /\A[a-z_][A-Za-z0-9_]*[?!]?\z/

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :path, format: { with: PATH, message: "must be <node>/<app>/<object>" }
  validates :method_name, format: { with: METHOD }, if: -> { kind == "call" }
  validates :timeout_s, numericality: { greater_than: 0, less_than_or_equal_to: MAX_TIMEOUT }
  validate :arguments_are_json

  scope :pending, -> { where(status: "pending") }

  def args_value
    args.present? ? JSON.parse(args) : []
  end

  def kwargs_value
    kwargs.present? ? JSON.parse(kwargs) : {}
  end

  def result_value
    result.present? ? JSON.parse(result) : nil
  end

  def done?
    !%w[pending running].include?(status)
  end

  def as_payload
    { "id" => id, "kind" => kind, "path" => path, "method" => method_name, "args" => args_value,
      "kwargs" => kwargs_value, "status" => status, "result" => result_value,
      "error_class" => error_class, "error_message" => error_message, "took_ms" => took_ms }
  end

  private

  def arguments_are_json
    a = args.present? ? JSON.parse(args) : []
    errors.add(:args, "must be a JSON array") unless a.is_a?(Array)
    k = kwargs.present? ? JSON.parse(kwargs) : {}
    errors.add(:kwargs, "must be a JSON object") unless k.is_a?(Hash)
  rescue JSON::ParserError => e
    errors.add(:args, "is not JSON (#{e.message.lines.first.strip})")
  end
end
