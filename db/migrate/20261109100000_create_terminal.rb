# The Terminal (0.3.15, docs/terminal.md): the asterism command line's
# commands typed on a page and run by the bridge on its connection.
#
# terminal_sessions: an open Terminal page (a random token per page),
# renewed while the page is open; the bridge stops the commands of a page
# whose row is gone or ran out.
# terminal_commands: each command line typed (kind "run"), which is also
# the record shown with the call log (who, when, the line, what it did,
# how it ended, the start of its output); and a Tab's completion while it
# is asked (kind "complete", removed once answered). New tables; nothing
# else changes.
class CreateTerminal < ActiveRecord::Migration[8.1]
  def change
    create_table :terminal_sessions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :page, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :terminal_sessions, :page, unique: true

    create_table :terminal_commands do |t|
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :page, null: false
      t.string :kind, null: false, default: "run" # run / complete
      t.text :line, null: false                   # as typed
      t.text :argv                                # its words (JSON), after "asterism"
      t.string :command                           # "node list", "call", ...
      t.string :effect                            # read / call / local (CLI.kind)
      t.string :path                              # what a call calls
      t.string :method_name
      t.integer :cols, null: false, default: 80
      t.string :status, null: false, default: "pending"
      t.integer :exit_code
      t.text :reason                              # why it was refused or stopped
      t.text :output                              # the start of what it printed (the summary)
      t.integer :output_bytes, null: false, default: 0
      t.float :took_ms
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :terminal_commands, [ :kind, :status ]
    add_index :terminal_commands, :created_at
  end
end
