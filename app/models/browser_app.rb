# An app "Launch Web Studio" may start (0.3.12, Admin > Studio apps): a path
# (or whatever the page understands), with an optional label and place in
# the menus. Make a pass offers "Nothing" and these; the rooms' page offers
# them after ASTERISM_ROOM_APPS (RoomPage.apps). Before 0.3.12 each role had
# one ("Opens in a browser page"); the migration copied them here.
class BrowserApp < ApplicationRecord
  # Free text within these characters (it travels in a URL fragment).
  PATH = %r{\A[A-Za-z0-9_./-]{1,200}\z}

  normalizes :path, with: -> { _1.to_s.strip }
  normalizes :label, with: -> { _1.to_s.strip.presence }

  validates :path, format: { with: PATH, message: "is letters, digits, _ . / - (up to 200)" }, uniqueness: true
  validates :label, length: { maximum: 80 }
  validates :position, numericality: { only_integer: true }, allow_nil: true

  # The menus' order: by position (those without last), then the labelled
  # ones by label, then the rest by path.
  scope :in_order, -> { order(Arel.sql("position IS NULL, position, label IS NULL, LOWER(label), path")) }

  # [label, value] for a select.
  def option
    [ label ? "#{label} (#{path})" : path, path ]
  end
end
