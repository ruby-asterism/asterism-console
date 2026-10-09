# A playback of a recording to the network (V4): the bridge republishes
# the recorded messages at the recorded pace times speed. ROS 2 topics go
# out through a ROS 2 node of the console's own (its own liveliness tokens,
# GID, sequence numbers and source times); Asterism keys as they were
# recorded. The network structure is never sent.
#
# Only an admin may start one (it injects traffic), after confirming; the
# rows are the audit log of what was sent, by whom and when (shown on the
# call log page). Playing "in the page only" sends nothing and leaves no row.
class Playback < ApplicationRecord
  SPEEDS = [ 0.25, 1.0, 4.0 ].freeze
  STATUSES = %w[pending running stopping done stopped failed].freeze
  ACTIVE = %w[pending running stopping].freeze
  # A request the bridge has not picked up in this time is dropped.
  EXPIRE_AFTER = 30.seconds

  belongs_to :user, optional: true
  belongs_to :recording, optional: true

  validates :speed, inclusion: { in: SPEEDS }
  validates :status, inclusion: { in: STATUSES }
  validate :one_at_a_time, on: :create
  validate :recording_is_readable, on: :create

  scope :active, -> { where(status: ACTIVE) }

  before_validation(on: :create) { self.recording_name ||= recording&.name }

  def channel_ids
    channels.present? ? JSON.parse(channels).map(&:to_i) : []
  end

  def channel_ids=(ids)
    self.channels = JSON.generate(Array(ids).map(&:to_i).uniq)
  end

  def skipped_value
    skipped.present? ? JSON.parse(skipped) : {}
  end

  def active? = ACTIVE.include?(status)

  def stop!
    if status == "pending"
      update!(status: "stopped", error: "stopped before the bridge started it", finished_at: Time.current)
    elsif status == "running"
      update!(status: "stopping")
    end
  end

  def as_payload
    { "id" => id, "recording_id" => recording_id, "recording" => recording_name, "speed" => speed,
      "status" => status, "channels" => channel_ids, "start_ns" => start_ns, "messages_sent" => messages_sent,
      "skipped" => skipped_value, "error" => error, "user" => user&.email_address,
      "at" => created_at&.iso8601, "started_at" => started_at&.iso8601, "finished_at" => finished_at&.iso8601 }
  end

  private

  def one_at_a_time
    errors.add(:base, "another playback is running (stop it first)") if self.class.active.exists?
  end

  def recording_is_readable
    errors.add(:recording, "is not a finished recording") unless recording&.finished? && recording.file?
  end
end
