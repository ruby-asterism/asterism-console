# The remote shell's get and put (docs/terminal.md, "Files: get and put"):
# the record of what a line carried (terminal_commands.files, JSON: the
# upload of a put while it waits, then each file's path on the machine, its
# size and how it ended).
class RemoteShellFiles < ActiveRecord::Migration[8.1]
  def change
    add_column :terminal_commands, :files, :text
  end
end
