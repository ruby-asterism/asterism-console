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

ActiveRecord::Schema[8.1].define(version: 2026_10_08_155857) do
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
    t.index ["status"], name: "index_bridge_requests_on_status"
  end

  create_table "graph_states", force: :cascade do |t|
    t.integer "version", default: 0, null: false
    t.text "snapshot"
    t.datetime "bridge_seen_at"
    t.text "bridge_info"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "watches", force: :cascade do |t|
    t.string "key", null: false
    t.string "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_watches_on_key", unique: true
  end
end
