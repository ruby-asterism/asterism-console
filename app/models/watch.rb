# A key the page wants to see the values of. The bridge subscribes to every
# Watch row and sends what arrives over Action Cable.
class Watch < ApplicationRecord
  validates :key, presence: true, uniqueness: true, length: { maximum: 200 },
                  format: { without: /\s/, message: "must not contain spaces" }

  def as_payload
    { "id" => id, "key" => key, "error" => error }
  end
end
