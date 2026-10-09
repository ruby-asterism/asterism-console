class CreateRelayPeers < ActiveRecord::Migration[8.1]
  def change
    # The relay registry: routers and clients that may connect to the cloud
    # router. The name is the certificate's common name, the ACL's subject
    # and (by convention) the Asterism node ID or the router's name.
    create_table :relay_peers do |t|
      t.string :name, null: false
      t.string :kind, null: false, default: "client"
      t.string :description
      t.text :rw_keys            # key expressions it may read and write, one per line
      t.text :ro_keys            # key expressions it may only read
      t.boolean :admin_space, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.text :dns_names          # a router that listens: extra names in its certificate
      t.text :ip_addresses
      t.integer :cert_days, null: false, default: 90
      t.timestamps
    end
    add_index :relay_peers, :name, unique: true

    # The ledger: every certificate the signer made for a peer (no keys).
    create_table :relay_certificates do |t|
      t.references :relay_peer, null: false, foreign_key: true
      t.string :serial, null: false
      t.string :fingerprint, null: false
      t.datetime :not_before, null: false
      t.datetime :not_after, null: false
      t.text :certificate_pem, null: false
      t.string :source, null: false, default: "signer" # signer / imported
      t.references :issued_by, foreign_key: { to_table: :users }
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :relay_certificates, :serial, unique: true

    # Every apply: the configuration written, what it cut, how it went.
    create_table :relay_applies do |t|
      t.references :user, foreign_key: true
      t.string :status, null: false, default: "running"
      t.string :config_digest
      t.text :config_text
      t.text :plan_json          # subjects added / removed, sessions to be cut
      t.text :after_json         # what came back
      t.text :output
      t.datetime :finished_at
      t.timestamps
    end
  end
end
