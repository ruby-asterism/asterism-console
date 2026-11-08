# Who each machine receives files from, per member row (0.3.16, T6,
# docs/files.md "Who a machine receives from"): two lists of node IDs and
# patterns (receive_files_from: the kind "file", receive_checkpoints_from:
# the kind "checkpoint", one per line), the time they last changed (which
# the machine keeps with its copy, and which makes the row a managed one:
# its nodes keep their transfer keys in the ACL so that an emptied list
# still reaches them) and what the bridge last delivered to each node (JSON).
# Nothing is filled in: a row receives from nobody through the console until
# an admin chooses, and the machines go on with what their receive.toml has
# by hand.
class MemberReceivers < ActiveRecord::Migration[8.1]
  def change
    add_column :relay_peers, :receive_files_from, :text
    add_column :relay_peers, :receive_checkpoints_from, :text
    add_column :relay_peers, :receivers_changed_at, :datetime
    add_column :relay_peers, :receivers_delivered, :text
  end
end
