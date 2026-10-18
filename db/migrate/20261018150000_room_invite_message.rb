# A message an admin writes for each invite link (CM4, 0.3.6): the link's
# page shows it above the form, e.g. how to make a room. Optional; the
# existing invite links keep none and their page looks as before.
class RoomInviteMessage < ActiveRecord::Migration[8.1]
  def change
    add_column :room_invites, :message, :text
  end
end
