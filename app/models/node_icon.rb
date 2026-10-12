# The icon of a node's profile (V2.5): PNG bytes kept by their icon_hash
# (Asterism::Profile.png_info). The bridge checked the bytes before writing
# them (Bridge::Profiles); IconsController serves them as they are. Kept
# after the node leaves: another node, a later visit or a recording's rewind
# shows the same icon without asking for it again.
class NodeIcon < ApplicationRecord
  HASH = /\A[0-9a-f]{8}\z/

  validates :icon_hash, presence: true, format: { with: HASH }, uniqueness: true
  validates :png, presence: true

  # Keeps an icon (a no-op when it is there). Returns the row.
  def self.keep(icon_hash, png, width, height)
    find_by(icon_hash: icon_hash) || create!(icon_hash: icon_hash, png: png.b, width: width, height: height)
  rescue ActiveRecord::RecordNotUnique
    find_by!(icon_hash: icon_hash)
  end

  # Which of these hashes have an icon here.
  def self.known(hashes)
    list = Array(hashes).compact.uniq
    return Set.new if list.empty?
    where(icon_hash: list).pluck(:icon_hash).to_set
  end
end
