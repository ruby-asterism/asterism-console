# A recording: an MCAP file under storage/recordings (gitignored), made by
# the bridge (source "recorded") or uploaded (source "uploaded").
#
# A recorded one is also the bridge's lease on what it records: while the
# row is "pending" or "recording" the bridge subscribes to its selection
# and writes the file; "stopping" (the page's Stop) and the limits
# (max_bytes, max_seconds) make it close the file, and the row ends "done"
# (or "failed", with error). Unlike the plot and log leases, nothing has to
# renew it: a recording runs until it is stopped or reaches a limit.
#
# selection: { "topics" => [ROS 2 topic ids, "r_topic:0/cmd_vel"],
#              "keys" => [Asterism key expressions],
#              "structure" => true/false (the network's graph, channel
#              /asterism/graph) }
#
# messages, bytes, duration_s and channel_counts are the progress the
# bridge writes about once a second (lost: messages the subscriptions
# dropped before they could be written, or that failed to be written); info is what MCAP::Reader says of the
# finished (or uploaded) file, kept so the list does not read every file.
class Recording < ApplicationRecord
  STATUSES = %w[pending recording stopping done failed uploaded].freeze
  ACTIVE = %w[pending recording stopping].freeze
  SOURCES = %w[recorded uploaded].freeze
  GRAPH_TOPIC = "/asterism/graph".freeze
  MB = 1024 * 1024
  DEFAULT_MAX_BYTES = 64 * MB
  LIMIT_MAX_BYTES = 512 * MB
  DEFAULT_MAX_SECONDS = 300
  LIMIT_MAX_SECONDS = 3600
  MAX_ACTIVE = 2
  MAX_TOPICS = 32
  MAX_KEYS = 16
  MAX_UPLOAD = 256 * MB
  # All recordings together: a new one (or an upload) is refused above it.
  MAX_TOTAL = Integer(ENV.fetch("ASTERISM_RECORDINGS_MAX_BYTES", 4 * 1024 * MB))
  FILENAME = /\A[A-Za-z0-9_-]+\.mcap\z/
  KEY = %r{\A[^@\s][^\s]{0,199}\z}

  belongs_to :user, optional: true
  has_many :playbacks, dependent: :nullify

  validates :name, presence: true, length: { maximum: 120 }
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :filename, format: { with: FILENAME }, uniqueness: true
  validates :max_bytes, numericality: { greater_than_or_equal_to: MB, less_than_or_equal_to: LIMIT_MAX_BYTES }
  validates :max_seconds, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: LIMIT_MAX_SECONDS }
  validate :selection_is_valid, if: -> { source == "recorded" }
  validate :room_for_another, on: :create, if: -> { source == "recorded" }

  scope :active, -> { where(status: ACTIVE) }
  scope :newest_first, -> { order(id: :desc) }

  before_validation on: :create do
    self.filename ||= self.class.new_filename
    self.max_bytes ||= DEFAULT_MAX_BYTES
    self.max_seconds ||= DEFAULT_MAX_SECONDS
    self.name = name.to_s.strip.presence || "recording #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}"
  end

  after_destroy_commit { FileUtils.rm_f(path) }

  def self.dir
    Pathname(ENV.fetch("ASTERISM_RECORDINGS_DIR", Rails.root.join("storage/recordings").to_s))
  end

  def self.new_filename
    "#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}.mcap"
  end

  # Bytes of all recordings (the files on disk, or the progress of running ones).
  def self.total_bytes
    all.sum { |r| r.file? ? File.size(r.path) : r.bytes.to_i }
  end

  def path
    raise ArgumentError, "bad file name" unless FILENAME.match?(filename.to_s)
    self.class.dir.join(filename)
  end

  def file? = File.file?(path)
  def active? = ACTIVE.include?(status)
  def finished? = %w[done uploaded].include?(status) || (status == "failed" && file?)

  def selection_value
    v = selection.present? ? JSON.parse(selection) : {}
    { "topics" => Array(v["topics"]), "keys" => Array(v["keys"]), "structure" => v["structure"] == true }
  rescue JSON::ParserError
    { "topics" => [], "keys" => [], "structure" => false }
  end

  def selection_value=(v)
    self.selection = JSON.generate("topics" => Array(v["topics"]).map(&:to_s).uniq,
                                   "keys" => Array(v["keys"]).map { _1.to_s.strip }.reject(&:empty?).uniq,
                                   "structure" => [ true, "1", "true", "on" ].include?(v["structure"]))
  end

  def channel_counts_value
    channel_counts.present? ? JSON.parse(channel_counts) : {}
  end

  def info_value
    info.present? ? JSON.parse(info) : nil
  end

  # The page's Stop. A recording the bridge has not started yet ends here.
  def stop!
    if status == "pending"
      update!(status: "failed", stop_reason: "stopped before the bridge started it", finished_at: Time.current)
    elsif status == "recording"
      update!(status: "stopping")
    end
  end

  # Reads the finished file's summary into info (once).
  def read_info!
    return info_value if info.present?
    r = MCAP::Reader.new(path.to_s)
    begin
      update!(info: JSON.generate(r.info))
    ensure
      r.close
    end
    info_value
  end

  def owned_by?(u) = u && (u.admin? || user_id == u.id)

  def as_payload
    { "id" => id, "name" => name, "source" => source, "status" => status, "filename" => filename,
      "selection" => selection_value, "max_bytes" => max_bytes, "max_seconds" => max_seconds,
      "messages" => messages, "lost" => lost, "bytes" => bytes, "duration_s" => duration_s.round(1),
      "channel_counts" => channel_counts_value, "stop_reason" => stop_reason, "error" => error,
      "started_at" => started_at&.iso8601, "finished_at" => finished_at&.iso8601,
      "user" => user&.email_address, "size" => file? ? File.size(path) : nil }
  end

  private

  def selection_is_valid
    s = selection_value
    errors.add(:selection, "is empty: pick topics, keys or the network structure") if
      s["topics"].empty? && s["keys"].empty? && !s["structure"]
    errors.add(:selection, "has more than #{MAX_TOPICS} topics") if s["topics"].size > MAX_TOPICS
    errors.add(:selection, "has more than #{MAX_KEYS} keys") if s["keys"].size > MAX_KEYS
    bad = s["topics"].reject { RateLease::TOPIC.match?(_1) }
    errors.add(:selection, "has topics that are not topic ids: #{bad.first(3).join(', ')}") if bad.any?
    bad = s["keys"].reject { KEY.match?(_1) }
    errors.add(:selection, "has keys that are not key expressions (or are in the admin space): #{bad.first(3).join(', ')}") if bad.any?
  end

  def room_for_another
    errors.add(:base, "#{MAX_ACTIVE} recordings are running already") if self.class.active.count >= MAX_ACTIVE
    errors.add(:base, "the recordings take #{MAX_TOTAL / MB} MB already (ASTERISM_RECORDINGS_MAX_BYTES)") if
      self.class.total_bytes >= MAX_TOTAL
  end
end
