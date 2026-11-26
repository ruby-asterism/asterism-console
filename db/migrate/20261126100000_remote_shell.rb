# The remote shell (docs/terminal.md, "The remote shell"): who may use it
# (users.rshell_access: none, read, write; none by default, admins too), the
# machines and browsers that let the console in (rshell_from_console, a mark
# beside the file marks, sent to them with the receivers' lists), the
# machine a Terminal page is in (terminal_sessions.remote, the bridge's
# copy for Rails) and the remote lines in the record
# (terminal_commands.remote: the machine; confirmed: the line was confirmed
# after the question about the system's area).
class RemoteShell < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :rshell_access, :string, null: false, default: "none"
    add_column :users, :rshell_from_console, :boolean, null: false, default: false
    add_column :relay_peers, :rshell_from_console, :boolean, null: false, default: false
    add_column :terminal_sessions, :remote, :text
    add_column :terminal_commands, :remote, :string
    add_column :terminal_commands, :confirmed, :boolean, null: false, default: false
  end
end
