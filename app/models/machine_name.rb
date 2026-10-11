# A name for a machine of ROS 2 nodes (V2.3): the console folds the ROS 2
# nodes that come from the same IP address into one group (Bridge::Groups)
# and shows it by its IP, or by the name an admin gave it here. The name is
# kept with the ROS 2 node names of the group it was given to ("members"),
# not with the IP, which changes (a container made again, DHCP): a group
# later takes the name when its node names overlap these enough
# (Bridge::Groups.overlap?). Shared by everyone; only admins change it
# (MachineNamesController).
class MachineName < ApplicationRecord
  MAX_MEMBERS = 500

  belongs_to :created_by, class_name: "User", optional: true

  validates :name, presence: true, length: { maximum: 64 }
  validate :members_are_names

  normalizes :name, with: ->(n) { n.to_s.strip }

  def member_list
    JSON.parse(members.to_s)
  rescue JSON::ParserError
    []
  end

  def member_list=(list)
    self.members = JSON.generate(Array(list).map { _1.to_s.strip }.reject(&:empty?).uniq.sort)
  end

  # What Bridge::Groups takes.
  def to_graph
    { "id" => id, "name" => name, "members" => member_list }
  end

  def self.for_graph
    order(:id).map(&:to_graph)
  end

  def as_payload
    to_graph.merge("created_by" => created_by&.email_address, "updated_at" => updated_at&.utc&.iso8601)
  end

  private

  def members_are_names
    list = member_list
    if list.empty?
      errors.add(:members, "must name at least one ROS 2 node")
    elsif list.size > MAX_MEMBERS || list.any? { !_1.is_a?(String) || _1.size > 255 }
      errors.add(:members, "must be a list of ROS 2 node names")
    end
  end
end
