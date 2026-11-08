# Sending files (T4, docs/files.md): a row of the call permissions is
# either a call ("call": node, app, object and method, as before) or "this
# node may be sent files" ("file": the node pattern; the console sends to
# its <node>/transfer/inbox). Every existing row is a call row.
class CallPermissionsKind < ActiveRecord::Migration[8.1]
  def change
    add_column :call_permissions, :kind, :string, null: false, default: "call"
  end
end
