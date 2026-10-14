require "test_helper"
require "tmpdir"

# The backups of 0.1.3 (lib/console_backup.rb): real SQLite files in a
# temporary directory, no Rails database involved.
class ConsoleBackupTest < ActiveSupport::TestCase
  ROOT = Rails.root.to_s

  setup do
    @tmp = Dir.mktmpdir("console-backup")
    @storage = File.join(@tmp, "storage")
    @backups = File.join(@tmp, "backups")
    FileUtils.mkdir_p(@storage)
  end

  teardown { FileUtils.rm_rf(@tmp) }

  def make_db(name, migration: "20261014090000", rows: [ "a" ])
    db = SQLite3::Database.new(File.join(@storage, name))
    db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version varchar NOT NULL PRIMARY KEY)")
    db.execute("INSERT OR IGNORE INTO schema_migrations VALUES (?)", [ migration ]) if migration
    db.execute("CREATE TABLE IF NOT EXISTS items (name text)")
    rows.each { db.execute("INSERT INTO items VALUES (?)", [ _1 ]) }
    db
  end

  def items(path)
    db = SQLite3::Database.new(path, readonly: true)
    db.execute("SELECT name FROM items ORDER BY rowid").flatten
  ensure
    db&.close
  end

  def maker(now:, **kw)
    ConsoleBackup::Maker.new(storage: @storage, backup_dir: @backups, rails_env: "production",
                             version: "0.1.3", root: ROOT, now: now, **kw)
  end

  test "a backup copies a live database in WAL mode, with a manifest" do
    db = make_db("production.sqlite3", rows: %w[one two])
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("INSERT INTO items VALUES ('in the wal')")
    make_db("production_cache.sqlite3", migration: nil).close
    make_db("development.sqlite3").close # another environment's: not taken

    e = maker(now: Time.utc(2026, 10, 14, 3, 0, 0), data_version: "0.1.2", label: "before-0.1.3").run
    assert_equal "asterism-20261014-030000-0.1.2-before-0.1.3.tar.gz", e.name
    m = e.manifest
    assert_equal "0.1.2", m["console_version"]
    assert_equal "0.1.3", m["made_by"]
    assert_equal "20261014090000", m["migration"]
    assert_equal %w[production.sqlite3 production_cache.sqlite3], m["databases"].map { _1["file"] }
    assert_empty Dir.children(@backups).select { _1.start_with?(".") } # no work or partial files left

    # the WAL's rows are in the copy: restore into an empty storage and read
    db.close
    FileUtils.rm_rf(Dir[File.join(@storage, "*")])
    ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3", root: ROOT).run
    assert_equal [ "one", "two", "in the wal" ], items(File.join(@storage, "production.sqlite3"))
    assert File.exist?(File.join(@storage, "production_cache.sqlite3"))
  ensure
    db&.close unless db&.closed?
  end

  test "no databases is an error and leaves no file" do
    err = assert_raises(ConsoleBackup::Error) { maker(now: Time.now).run }
    assert_match(/no production databases/, err.message)
    assert_empty ConsoleBackup.list(@backups) if File.directory?(@backups)
  end

  test "rotation keeps the newest N" do
    make_db("production.sqlite3").close
    names = (1..5).map { |d| maker(now: Time.utc(2026, 10, d, 3)).run.name }
    gone = ConsoleBackup.rotate(@backups, keep: 3)
    assert_equal names.first(2).reverse, gone
    assert_equal names.last(3).reverse, ConsoleBackup.list(@backups).map(&:name)
    File.write(File.join(@backups, "notes.txt"), "kept") # not a backup: never touched
    ConsoleBackup.rotate(@backups, keep: 1)
    assert File.exist?(File.join(@backups, "notes.txt"))
    assert_equal 1, ConsoleBackup.list(@backups).size
  end

  test "two backups in the same second get distinct names" do
    make_db("production.sqlite3").close
    t = Time.utc(2026, 10, 14, 3)
    a = maker(now: t).run.name
    b = maker(now: t).run.name
    refute_equal a, b
  end

  test "keep and hour come from the environment" do
    assert_equal 7, ConsoleBackup.keep({})
    assert_equal 3, ConsoleBackup.keep("ASTERISM_BACKUP_KEEP" => "3")
    assert_raises(ConsoleBackup::Error) { ConsoleBackup.keep("ASTERISM_BACKUP_KEEP" => "0") }
    assert_raises(ConsoleBackup::Error) { ConsoleBackup.keep("ASTERISM_BACKUP_KEEP" => "many") }
    assert_equal 3, ConsoleBackup.hour({})
    assert_equal 0, ConsoleBackup.hour("ASTERISM_BACKUP_HOUR" => "0")
    assert_equal 9, ConsoleBackup.hour("ASTERISM_BACKUP_HOUR" => "09")
    assert_raises(ConsoleBackup::Error) { ConsoleBackup.hour("ASTERISM_BACKUP_HOUR" => "24") }
  end

  test "restore replaces the databases and drops their WAL files" do
    make_db("production.sqlite3", rows: [ "old" ]).close
    e = maker(now: Time.utc(2026, 10, 14, 3)).run
    db = make_db("production.sqlite3", rows: [ "new" ])
    db.close
    File.write(File.join(@storage, "production.sqlite3-wal"), "stale")
    notes = ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3", root: ROOT).run
    assert_equal [ "old" ], items(File.join(@storage, "production.sqlite3"))
    refute File.exist?(File.join(@storage, "production.sqlite3-wal"))
    assert_empty notes
    assert_empty Dir[File.join(@storage, ".restore-*")]
  end

  test "restore refuses while a console or bridge holds the lock, unless forced" do
    make_db("production.sqlite3", rows: [ "old" ]).close
    e = maker(now: Time.utc(2026, 10, 14, 3)).run
    make_db("production.sqlite3", rows: [ "new" ]).close
    # another process stands in for the running console (flock is per open file)
    r, w = IO.pipe
    pid = fork do
      r.close
      ConsoleBackup::Lock.hold_shared(@storage)
      w.puts "held"
      sleep 30
    end
    w.close
    assert_equal "held", r.gets.strip
    restorer = ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3", root: ROOT)
    err = assert_raises(ConsoleBackup::Error) { restorer.run }
    assert_match(/docker compose stop console bridge backup/, err.message)
    assert_equal %w[old new], items(File.join(@storage, "production.sqlite3"))

    notes = ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3",
                                        root: ROOT, force: true).run
    assert(notes.any? { _1.include?("--force") })
    assert_equal [ "old" ], items(File.join(@storage, "production.sqlite3"))
  ensure
    if pid
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end

  test "restore warns across a migration and across versions" do
    make_db("production.sqlite3", migration: "20261013120200").close
    e = maker(now: Time.utc(2026, 10, 14, 3), data_version: "0.1.2").run
    make_db("production.sqlite3", migration: "20261014090000").close # the update migrated it
    notes = ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3", root: ROOT).run
    assert(notes.any? { _1.include?("console 0.1.2's data") })
    assert(notes.any? { _1.include?("across a migration") && _1.include?("update.sh 0.1.2") })
  end

  test "restore refuses a newer console's data unless forced" do
    make_db("production.sqlite3", migration: "29991231000000").close
    e = maker(now: Time.utc(2026, 10, 14, 3), data_version: "9.0.0").run
    r = ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3", root: ROOT)
    assert_raises(ConsoleBackup::Error) { r.check }
    assert_raises(ConsoleBackup::Error) do
      ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: "asterism-nope.tar.gz", version: "0.1.3", root: ROOT).run
    end
  end

  test "restore checks the files against the manifest" do
    make_db("production.sqlite3").close
    e = maker(now: Time.utc(2026, 10, 14, 3)).run
    bytes = File.binread(e.path)
    File.binwrite(e.path, bytes[0, bytes.size / 2])
    err = assert_raises(ConsoleBackup::Error) do
      ConsoleBackup::Restorer.new(storage: @storage, backup_dir: @backups, name: e.name, version: "0.1.3", root: ROOT).run
    end
    assert_match(/not a readable backup|lacks|checksum/, err.message)
  end

  test "status: a failure warns until the next good backup, and an old one warns too" do
    now = Time.utc(2026, 10, 14, 3)
    assert_nil ConsoleBackup::Status.warning(@backups, now: now)
    ConsoleBackup::Status.record(@backups, ok: true, name: "asterism-x.tar.gz", now: now)
    assert_nil ConsoleBackup::Status.warning(@backups, now: now + 3600)
    assert_match(/No backup since/, ConsoleBackup::Status.warning(@backups, now: now + 3 * 86_400))
    ConsoleBackup::Status.record(@backups, ok: false, error: "disk full", now: now + 86_400)
    assert_match(/failed.*disk full/, ConsoleBackup::Status.warning(@backups, now: now + 86_400))
    ConsoleBackup::Status.record(@backups, ok: true, name: "asterism-y.tar.gz", now: now + 86_500)
    assert_nil ConsoleBackup::Status.warning(@backups, now: now + 86_600)
    assert_equal "asterism-y.tar.gz", ConsoleBackup::Status.read(@backups)["last_ok_name"]
    ConsoleBackup::Status.record(@backups, ok: false, error: "again", now: now + 86_500.25) # the same second
    assert_match(/again/, ConsoleBackup::Status.warning(@backups, now: now + 86_600))
  end
end

# The daily backup (the "backup" service's loop).
class ConsoleBackupDailyTest < ActiveSupport::TestCase
  setup do
    @tmp = Dir.mktmpdir("console-backup-daily")
    @storage = File.join(@tmp, "storage")
    @backups = File.join(@tmp, "backups")
    FileUtils.mkdir_p(@storage)
    @now = Time.utc(2026, 10, 14, 1, 30)
    @out = StringIO.new
  end

  teardown { FileUtils.rm_rf(@tmp) }

  def daily(hour: 3, keep: 2)
    ConsoleBackup::Daily.new(storage: @storage, backup_dir: @backups, rails_env: "production", version: "0.1.3",
                             root: Rails.root.to_s, hour: hour, keep: keep, out: @out, clock: -> { @now })
  end

  def make_db
    db = SQLite3::Database.new(File.join(@storage, "production.sqlite3"))
    db.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")
    db.close
  end

  test "the next run is today at the hour, or tomorrow once it has passed" do
    assert_equal Time.utc(2026, 10, 14, 3), daily.next_run(Time.utc(2026, 10, 14, 1, 30))
    assert_equal Time.utc(2026, 10, 15, 3), daily.next_run(Time.utc(2026, 10, 14, 3, 0))
    assert_equal Time.utc(2026, 10, 15, 3), daily.next_run(Time.utc(2026, 10, 14, 22, 0))
    assert_equal Time.utc(2026, 11, 1, 0), daily(hour: 0).next_run(Time.utc(2026, 10, 31, 23, 59))
  end

  test "a run makes a backup, rotates and records the status; a failure is recorded and does not raise" do
    refute daily.run_once # no databases yet
    assert_match(/no production databases/, ConsoleBackup::Status.read(@backups)["last_error"])
    assert_match(/FAILED/, @out.string)
    assert ConsoleBackup::Status.warning(@backups, now: @now)

    make_db
    3.times do
      @now += 86_400
      assert daily.run_once
    end
    assert_equal 2, ConsoleBackup.list(@backups).size
    s = ConsoleBackup::Status.read(@backups)
    assert_nil s["last_error"]
    assert_match(/-daily\.tar\.gz\z/, s["last_ok_name"])
    assert_equal 2, s["keep"]
    assert_nil ConsoleBackup::Status.warning(@backups, now: @now)
  end

  Stop = Class.new(StandardError) # Kernel#loop swallows StopIteration

  test "the loop catches up at start, then runs at the hour" do
    make_db
    assert daily.due_at_start?
    runs = 0
    sleeper = lambda do |s|
      @now += s
      runs = ConsoleBackup.list(@backups).size
      raise Stop if runs >= 3
    end
    assert_raises(Stop) { daily(keep: 9).loop_forever(sleeper: sleeper) }
    names = ConsoleBackup.list(@backups).map(&:name).reverse
    assert_equal "asterism-20261014-013000-0.1.3-daily.tar.gz", names[0]   # at start
    assert_equal "asterism-20261014-030000-0.1.3-daily.tar.gz", names[1]   # at 03:00
    assert_equal "asterism-20261015-030000-0.1.3-daily.tar.gz", names[2]   # the next day
    refute daily.due_at_start?
  end
end
