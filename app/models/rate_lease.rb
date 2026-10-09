# A page asking the bridge to measure topic rates: key "*" (every ROS 2
# topic, one wildcard subscription per domain) or a topic id
# ("r_topic:0/chatter", that topic only). A page renews its leases while it
# wants them (RatesController); the bridge measures what has a live lease
# and stops when they run out, so a closed page costs nothing for long.
class RateLease < ApplicationRecord
  LIFETIME = 30.seconds
  TOPIC = %r{\Ar_topic:\d+(/[A-Za-z0-9_~.-]+)+\z}

  validates :key, presence: true, uniqueness: true
  validate { errors.add(:key, "is not * or a topic id") unless key == "*" || TOPIC.match?(key.to_s) }

  scope :live, -> { where(expires_at: Time.current..) }

  def self.renew(key)
    lease = find_or_initialize_by(key: key)
    lease.expires_at = LIFETIME.from_now
    lease.save && lease
  rescue ActiveRecord::RecordNotUnique
    retry # two pages renewed the same new key at once: the other one made it
  end

  # The live keys, the expired rows removed.
  def self.wanted
    where(expires_at: ...Time.current).delete_all
    live.pluck(:key).sort
  end

  # The data key expression the bridge subscribes to for a topic id:
  # r_topic:0/chatter -> 0/chatter/** (rmw_zenoh adds the type and its hash).
  def self.key_expr(topic_id)
    "#{topic_id.delete_prefix('r_topic:')}/**"
  end
end
