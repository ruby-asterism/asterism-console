class AddUserToBridgeRequests < ActiveRecord::Migration[8.1]
  def change
    # Who asked (the call log). Requests from before W2 have none.
    add_reference :bridge_requests, :user, null: true, foreign_key: true
    add_index :bridge_requests, :created_at
  end
end
