# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_09_003318) do
  create_table "bridge_requests", force: :cascade do |t|
    t.string "kind"
    t.string "path"
    t.string "method_name"
    t.text "args"
    t.text "kwargs"
    t.float "timeout_s", default: 2.0, null: false
    t.string "status", default: "pending", null: false
    t.text "result"
    t.string "error_class"
    t.text "error_message"
    t.float "took_ms"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["created_at"], name: "index_bridge_requests_on_created_at"
    t.index ["status"], name: "index_bridge_requests_on_status"
    t.index ["user_id"], name: "index_bridge_requests_on_user_id"
  end

  create_table "call_permissions", force: :cascade do |t|
    t.string "node", null: false
    t.string "app", null: false
    t.string "object", null: false
    t.string "method_name", null: false
    t.string "note"
    t.integer "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_call_permissions_on_created_by_id"
  end

  create_table "graph_states", force: :cascade do |t|
    t.integer "version", default: 0, null: false
    t.text "snapshot"
    t.datetime "bridge_seen_at"
    t.text "bridge_info"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "admin", default: false, null: false
    t.string "otp_secret"
    t.datetime "otp_enabled_at"
    t.integer "otp_last_step"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "watches", force: :cascade do |t|
    t.string "key", null: false
    t.string "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_watches_on_key", unique: true
  end

  add_foreign_key "bridge_requests", "users"
  add_foreign_key "call_permissions", "users", column: "created_by_id"
  add_foreign_key "sessions", "users"
end
