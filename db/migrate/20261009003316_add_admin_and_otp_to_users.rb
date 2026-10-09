class AddAdminAndOtpToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :admin, :boolean, null: false, default: false
    # TOTP (rotp): the shared secret, when it was confirmed, and the last
    # time step used (a code is accepted once).
    add_column :users, :otp_secret, :string
    add_column :users, :otp_enabled_at, :datetime
    add_column :users, :otp_last_step, :integer
  end
end
