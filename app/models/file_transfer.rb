# A file sent to a machine or received from one (T4, docs/files.md): the
# record (who, when, the file's name, size and SHA-256, the other node, how
# it ended) and, for a file being sent, the bridge's lease on it.
#
# Sending: the page uploads the file into the outbox (storage/transfers/
# outbox, gitignored) and writes a "pending" row; the bridge (bin/bridge,
# node "console") sends it to <node>/transfer/inbox in pieces with
# resending (Asterism::Transfer::Sender), writes the progress into the row
# ("sending", done_bytes) and the end ("done" with placed_name, "failed"
# with the reason, "cancelled" after the page's Cancel: "cancelling"), then
# deletes the upload. Only the nodes of the members marked "receives files
# from the console" (RelayPeer.file_receivers, T4b) may be sent to; a row
# for another node ends "denied".
#
# Receiving: the bridge answers at <console>/transfer/inbox
# (Asterism::Transfer::FileInbox) for the nodes of the members marked "may
# send files to the console" (RelayPeer.file_senders) and puts whole files
# into the inbox (storage/transfers/inbox);
# each file is a row ("receiving", then "done", "refused" or "dropped").
class FileTransfer < ApplicationRecord
  DIRECTIONS = %w[send receive].freeze
  SEND_STATUSES = %w[pending sending cancelling done failed cancelled denied].freeze
  RECEIVE_STATUSES = %w[receiving done refused dropped].freeze
  ACTIVE = %w[pending sending cancelling receiving].freeze
  MB = 1024 * 1024
  # The largest file the page uploads to send (nginx's client_max_body_size
  # must let it through).
  MAX_UPLOAD = Integer(ENV.fetch("ASTERISM_TRANSFER_UPLOAD_MAX_BYTES", 256 * MB))
  # All received files together (refused at begin above it).
  INBOX_MAX = Integer(ENV.fetch("ASTERISM_TRANSFER_INBOX_MAX_BYTES", 1024 * MB))
  # Files waiting to be sent, at most.
  MAX_PENDING = 8
  NODE = /\A[A-Za-z0-9_.-]{1,64}\z/
  STORED = /\A[0-9a-f]{24}\z/

  belongs_to :user, optional: true

  validates :direction, inclusion: { in: DIRECTIONS }
  validates :status, inclusion: { in: SEND_STATUSES + RECEIVE_STATUSES }
  validates :node, format: { with: NODE, message: "is not a node ID" }
  validates :name, presence: true, length: { maximum: 255 }
  validate :name_is_a_file_name, if: :sending?

  scope :newest_first, -> { order(id: :desc) }
  scope :sends, -> { where(direction: "send") }
  scope :receives, -> { where(direction: "receive") }
  scope :active, -> { where(status: ACTIVE) }

  after_destroy_commit { FileUtils.rm_f(outbox_path) if outbox_path }

  def self.dir
    Pathname(ENV.fetch("ASTERISM_TRANSFERS_DIR", Rails.root.join("storage/transfers").to_s))
  end

  def self.outbox = dir.join("outbox")
  def self.inbox = dir.join("inbox")
  def self.work = dir.join("work")

  # Whether the name is one a machine takes (the same rule as
  # Asterism::Transfer.file_name?; Puma does not load Asterism).
  def self.file_name?(name)
    return false unless name.is_a?(String) && name.valid_encoding?
    n = name.bytesize
    return false if n.zero? || n > 48 || name.start_with?(".") || name.include?("..")
    name.each_byte.none? { |c| c < 32 || c == 127 || c == 47 || c == 92 }
  end

  # The received files (the inbox, hidden pieces left out), newest first:
  # [{ "name", "size", "mtime" }].
  def self.received_files
    return [] unless File.directory?(inbox)
    Dir.children(inbox).reject { _1.start_with?(".") }.filter_map do |n|
      path = inbox.join(n)
      next unless File.file?(path)
      st = File.stat(path)
      { "name" => n, "size" => st.size, "mtime" => st.mtime }
    end.sort_by { -_1["mtime"].to_f }
  end

  # The path of one received file, or nil (not a plain name, not there).
  def self.received_path(name)
    return nil unless file_name?(name.to_s)
    path = inbox.join(name.to_s)
    File.file?(path) ? path : nil
  end

  def self.received_bytes
    received_files.sum { _1["size"] }
  end

  # The upload of a send waiting in the outbox.
  def outbox_path
    return nil unless direction == "send" && STORED.match?(stored.to_s)
    self.class.outbox.join(stored)
  end

  def active? = ACTIVE.include?(status)
  def sending? = direction == "send"

  # The page's Cancel. A row the bridge has not taken yet ends here.
  def cancel!
    if status == "pending"
      update!(status: "cancelled", reason: "cancelled before the bridge took it", finished_at: Time.current)
      FileUtils.rm_f(outbox_path) if outbox_path
    elsif status == "sending"
      update!(status: "cancelling")
    end
  end

  def owned_by?(u) = u && (u.admin? || user_id == u.id)

  def as_payload
    { "id" => id, "direction" => direction, "status" => status, "node" => node, "name" => name,
      "placed_name" => placed_name, "size" => size, "sha256" => sha256, "done_bytes" => done_bytes,
      "overwrite" => overwrite, "sd" => sd, "reason" => reason, "piece" => piece, "window" => window,
      "took_ms" => took_ms, "user" => user&.email_address, "at" => created_at&.iso8601,
      "started_at" => started_at&.iso8601, "finished_at" => finished_at&.iso8601 }
  end

  private

  def name_is_a_file_name
    errors.add(:name, "is not a file name a machine takes (1 to 48 bytes, no / \\ .., not starting with .)") unless
      self.class.file_name?(name)
  end
end
