# One apply of the registry to the cloud router: the configuration that was
# written, the plan shown before (who joins or leaves the ACL, which
# sessions on the cloud router are cut by the restart), the restart's
# output, and what was back on the cloud router afterwards.
class RelayApply < ApplicationRecord
  STATUSES = %w[running ok failed].freeze

  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES }

  def plan
    plan_json.present? ? JSON.parse(plan_json) : {}
  end

  def after
    after_json.present? ? JSON.parse(after_json) : {}
  end

  # How a session before the restart is found again after it: by what it
  # carries (the session ID of a client that opens a new session changes),
  # the console's own sessions as one, else by its label.
  def self.session_key(s)
    return "this console" if s["self"]
    s["carries"].to_a.any? ? s["carries"].sort.join(", ") : s["label"]
  end

  # [came back, not back] (session keys).
  def comparison
    before = plan["cut"].to_a.map { self.class.session_key(_1) }.uniq
    now = after["sessions"].to_a.map { self.class.session_key(_1) }.uniq
    [ before & now, before - now ]
  end

  def running?
    status == "running"
  end
end
