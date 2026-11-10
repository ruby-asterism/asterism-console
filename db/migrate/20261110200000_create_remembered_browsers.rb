# Browsers a user let skip the TOTP code for 30 days (T8c,
# RememberedBrowser): the SHA-256 of the cookie's value only, who, when, and
# the browser's user agent for the account page.
class CreateRememberedBrowsers < ActiveRecord::Migration[8.1]
  def change
    create_table :remembered_browsers do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :user_agent
      t.string :created_ip
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :remembered_browsers, :token_digest, unique: true
  end
end
