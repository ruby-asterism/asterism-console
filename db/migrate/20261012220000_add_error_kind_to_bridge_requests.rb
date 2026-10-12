# The kind of a remote error (asterism 0.7.0, protocol 1: RemoteError#remote_kind,
# e.g. "raised", "not_exposed", "arguments"), kept next to its class and message.
class AddErrorKindToBridgeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :bridge_requests, :error_kind, :string
  end
end
