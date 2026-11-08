# A command line typed in the Terminal (docs/terminal.md). Rails writes the
# row (pending, or denied with the reason when Terminal::Line refuses it),
# the bridge runs it with the asterism gem's command line on its own
# connection (Bridge::Terminal), streams the output to the page and writes
# how it ended.
#
# The rows of kind "run" are also the record, shown with the call log: who
# typed what, when, whether it read or called, how it ended (status, exit
# code, the reason), and the start of what it printed. Nobody removes them
# (no page or route does), and they are kept as long as the call log's rows.
# A Tab's completion is a row of kind "complete" while it is asked; the
# bridge answers it and removes it.
class TerminalCommand < ApplicationRecord
  KINDS = %w[run complete].freeze
  ACTIVE = %w[pending running stopping].freeze
  STATUSES = (ACTIVE + %w[ok failed denied stopped expired]).freeze
  # A command the bridge has not picked up within this time is dropped.
  EXPIRE_AFTER = 30.seconds
  # What the record keeps of the output (the summary).
  OUTPUT_KEPT = 2000
  # How many commands may run at once: per user, and in all. The page runs
  # one at a time.
  PER_USER = Integer(ENV.fetch("ASTERISM_TERMINAL_PER_USER", 3))
  MAX_RUNNING = Integer(ENV.fetch("ASTERISM_TERMINAL_MAX", 12))

  belongs_to :user, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :page, format: { with: TerminalSession::PAGE }
  validates :cols, numericality: { only_integer: true, in: 20..400 }

  scope :runs, -> { where(kind: "run") }
  scope :active, -> { where(status: ACTIVE) }

  def argv_value
    argv.present? ? JSON.parse(argv) : []
  end

  def active?
    ACTIVE.include?(status)
  end

  # Text without the colour codes, cut to what the record keeps.
  def self.summary(text)
    t = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
    t.bytesize > OUTPUT_KEPT ? "#{t.byteslice(0, OUTPUT_KEPT).scrub('')}..." : t
  end

  def as_payload
    { "id" => id, "kind" => kind, "line" => line, "command" => command, "effect" => effect, "path" => path,
      "method" => method_name, "status" => status, "exit_code" => exit_code, "reason" => reason,
      "output_bytes" => output_bytes, "took_ms" => took_ms, "user" => user&.email_address, "at" => created_at&.iso8601 }
  end
end
