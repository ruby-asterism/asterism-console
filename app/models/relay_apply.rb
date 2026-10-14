# One apply of the registry to the cloud router: the configuration that was
# written, the plan shown before (who joins or leaves the ACL, which
# sessions on the cloud router are cut by the restart), the restart's
# output, and what was back on the cloud router afterwards.
#
# When (G1.5b, mode): "now", "idle" (when nobody is connected:
# Relay::Applier.idle?) or "at" (run_at). The last two wait (status
# "waiting") until Relay::ApplyWaiter starts them, and can be cancelled
# meanwhile ("cancelled"). A waiting apply applies the registry as it is
# when it runs. One waits at a time: a new apply replaces it.
class RelayApply < ApplicationRecord
  STATUSES = %w[waiting running ok failed cancelled].freeze
  MODES = %w[now idle at].freeze
  # An apply that started this long ago and still says "running" is taken
  # as dead (the process went away), so another may start.
  RUNNING_FOR = 5.minutes

  belongs_to :user, optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }
  validates :run_at, presence: true, if: -> { mode == "at" }

  scope :waiting, -> { where(status: "waiting") }

  def self.running_now?
    where(status: "running").where(started_at: RUNNING_FOR.ago..).exists?
  end

  def self.waiting_one
    waiting.order(:id).last
  end

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

  def waiting?
    status == "waiting"
  end

  # What it waits for, in words.
  def when_text
    case mode
    when "idle" then "when nobody is connected"
    when "at" then "at #{run_at.in_time_zone.strftime('%Y-%m-%d %H:%M %Z')}"
    else "now"
    end
  end

  # Takes a waiting apply to run (true when this call took it): one UPDATE,
  # so the waiter and a cancel cannot both have it.
  def start!(at = Time.current)
    n = self.class.waiting.where(id: id).update_all(status: "running", started_at: at, updated_at: at)
    reload
    n == 1
  end

  def cancel!(by, at = Time.current)
    n = self.class.waiting.where(id: id).update_all(status: "cancelled", cancelled_at: at, cancelled_by_id: by&.id,
                                                    finished_at: at, updated_at: at)
    reload
    n == 1
  end
end
