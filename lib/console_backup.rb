# The console's backups (0.1.3): a consistent copy of its SQLite databases
# with a small manifest, as one .tar.gz in the backups directory (a volume
# of its own on a server, /backups). bin/asterism drives it:
#
#   bin/asterism backup [--label L] [--data-version V] [--no-rotate]
#   bin/asterism backups
#   bin/asterism restore <name> [--force]
#   bin/asterism backup-daily        # the "backup" service's loop
#
# Each database is copied with SQLite's VACUUM INTO, which reads one
# transaction's view of a live database (never a raw copy of a file that is
# being written). The newest ASTERISM_BACKUP_KEEP backups (default 7) are
# kept, older ones deleted. Recordings (storage/recordings) are not in it.
#
# The CA's key is not here: it lives in the signer's volume, made once, and
# the first setup asks for an encrypted copy off the server
# (docs/install.md, "Backups").
#
# A lock file in the storage directory keeps a restore from replacing the
# files under a running console or bridge: they hold it shared for their
# lifetime (config/initializers/storage_lock.rb, bin/bridge), a backup holds
# it shared while it copies, a restore needs it exclusively.
#
# Plain Ruby (sqlite3, json, zlib, rubygems' tar): bin/asterism uses it
# without loading Rails, and the console reads the status for its warning.
require "fileutils"
require "json"
require "time"
require "zlib"
require "digest"
require "rubygems/package"
require "sqlite3"

module ConsoleBackup
  class Error < StandardError; end

  FORMAT = 1
  PREFIX = "asterism-"
  SUFFIX = ".tar.gz"
  NAME_RE = /\Aasterism-\d{8}-\d{6}-[0-9A-Za-z.\-]+\.tar\.gz\z/
  MANIFEST = "manifest.json"
  STATUS = "status.json"
  LOCK = "asterism.lock"
  DEFAULT_KEEP = 7
  DEFAULT_HOUR = 3

  module_function

  def keep(env = ENV)
    n = env["ASTERISM_BACKUP_KEEP"].to_s.strip
    return DEFAULT_KEEP if n.empty?
    Integer(n).tap { raise Error, "ASTERISM_BACKUP_KEEP must be 1 or more" if _1 < 1 }
  rescue ArgumentError
    raise Error, "ASTERISM_BACKUP_KEEP is not a number: #{n}"
  end

  def hour(env = ENV)
    h = env["ASTERISM_BACKUP_HOUR"].to_s.strip
    return DEFAULT_HOUR if h.empty?
    Integer(h, 10).tap { raise Error, "ASTERISM_BACKUP_HOUR must be 0..23" unless (0..23).cover?(_1) }
  rescue ArgumentError
    raise Error, "ASTERISM_BACKUP_HOUR is not an hour (0..23): #{h}"
  end

  # Where the backups go: ASTERISM_BACKUP_DIR, else /backups when it exists
  # (the volume), else tmp/backups under the application (development).
  def dir(root, env = ENV)
    d = env["ASTERISM_BACKUP_DIR"].to_s
    return d unless d.empty?
    File.directory?("/backups") ? "/backups" : File.join(root, "tmp/backups")
  end

  # The latest migration the code knows (db/migrate), "0" when none.
  def code_migration(root)
    Dir[File.join(root, "db/migrate/*.rb")].map { File.basename(_1)[/\A\d+/] }.compact.max || "0"
  end

  # The lock file of a storage directory (see the top of the file).
  module Lock
    module_function

    HELD = [] # rubocop:disable Style/MutableConstant -- the open files must outlive the call

    def path(storage) = File.join(storage, LOCK)

    # A running console or bridge: shared for the process's lifetime.
    def hold_shared(storage)
      FileUtils.mkdir_p(storage)
      f = File.open(path(storage), File::RDWR | File::CREAT, 0o644)
      f.flock(File::LOCK_SH)
      HELD << f
      f
    rescue SystemCallError
      nil # a read-only or missing storage directory: nothing to protect
    end

    # Runs the block with the lock (:sh or :ex), not waiting for it; false
    # (and no block) when another process holds it the other way.
    def try(storage, mode)
      FileUtils.mkdir_p(storage)
      File.open(path(storage), File::RDWR | File::CREAT, 0o644) do |f|
        return false unless f.flock((mode == :ex ? File::LOCK_EX : File::LOCK_SH) | File::LOCK_NB)
        begin
          yield
        ensure
          f.flock(File::LOCK_UN)
        end
      end
      true
    end
  end

  # One backup file, read from its name and (when asked) its manifest.
  Entry = Struct.new(:name, :path, :bytes, :time) do
    def manifest
      @manifest ||= ConsoleBackup.read_manifest(path)
    end
  end

  def read_manifest(path)
    Zlib::GzipReader.open(path) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each { |e| return JSON.parse(e.read) if e.full_name == MANIFEST }
      end
    end
    raise Error, "#{File.basename(path)} has no #{MANIFEST}"
  rescue Zlib::Error, Gem::Package::TarInvalidError, JSON::ParserError => e
    raise Error, "#{File.basename(path)} is not a readable backup (#{e.message})"
  end

  # The backups in a directory, newest first (the name starts with the time).
  def list(backup_dir)
    Dir[File.join(backup_dir, "#{PREFIX}*#{SUFFIX}")].select { NAME_RE.match?(File.basename(_1)) }.map do |p|
      name = File.basename(p)
      t = Time.strptime(name[PREFIX.size, 15] + "Z", "%Y%m%d-%H%M%S%z")
      Entry.new(name, p, File.size(p), t)
    end.sort_by(&:name).reverse
  end

  # Deletes all but the newest `keep`; returns the names deleted.
  def rotate(backup_dir, keep:)
    list(backup_dir).drop(keep).map do |e|
      File.delete(e.path)
      e.name
    end
  end

  # The databases of one environment in a storage directory:
  # <env>.sqlite3 and <env>_<name>.sqlite3.
  def databases(storage, rails_env)
    Dir[File.join(storage, "*.sqlite3")].select do |p|
      b = File.basename(p, ".sqlite3")
      b == rails_env || b.start_with?("#{rails_env}_")
    end.sort
  end

  def migration_of(db_path)
    db = SQLite3::Database.new(db_path, readonly: true)
    db.busy_timeout = 5000
    return nil if db.get_first_value("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_migrations'").to_i.zero?
    db.get_first_value("SELECT max(version) FROM schema_migrations")&.to_s
  ensure
    db&.close
  end

  # Makes one backup; returns its Entry. Raises Error when there is nothing
  # to back up or a copy fails (no partial file is left behind).
  class Maker
    def initialize(storage:, backup_dir:, rails_env:, version:, root:, data_version: nil, label: nil, now: Time.now)
      @storage, @backup_dir, @rails_env, @version, @root = storage, backup_dir, rails_env, version, root
      @data_version = data_version.to_s.empty? ? version : data_version
      @label = label.to_s.empty? ? nil : label
      @now = now.utc
      raise Error, "label may hold letters, digits, '.' and '-' only" if @label && !@label.match?(/\A[0-9A-Za-z.\-]+\z/)
    end

    def run
      dbs = ConsoleBackup.databases(@storage, @rails_env)
      raise Error, "no #{@rails_env} databases in #{@storage} (bin/asterism setup makes them)" if dbs.empty?
      FileUtils.mkdir_p(@backup_dir)
      name = unique_name
      work = File.join(@backup_dir, ".#{name}.work")
      FileUtils.rm_rf(work)
      FileUtils.mkdir_p(work)
      entry = nil
      locked = ConsoleBackup::Lock.try(@storage, :sh) do
        files = dbs.map { copy(_1, work) }
        entry = write_tar(name, work, files)
      end
      raise Error, "a restore is running on #{@storage}; try again when it is done" unless locked
      entry
    ensure
      FileUtils.rm_rf(work) if work
    end

    private

    def unique_name
      base = "#{PREFIX}#{@now.strftime('%Y%m%d-%H%M%S')}-#{@data_version}#{"-#{@label}" if @label}"
      name = "#{base}#{SUFFIX}"
      n = 1
      while File.exist?(File.join(@backup_dir, name))
        n += 1
        name = "#{base}-#{n}#{SUFFIX}"
      end
      name
    end

    def copy(src, work)
      dst = File.join(work, File.basename(src))
      db = SQLite3::Database.new(src)
      db.busy_timeout = 10_000
      db.execute("VACUUM INTO ?", [ dst ])
      db.close
      check = SQLite3::Database.new(dst, readonly: true)
      ok = check.get_first_value("PRAGMA integrity_check")
      check.close
      raise Error, "the copy of #{File.basename(src)} failed its integrity check (#{ok})" unless ok == "ok"
      { "file" => File.basename(src), "bytes" => File.size(dst), "sha256" => Digest::SHA256.file(dst).hexdigest,
        "migration" => ConsoleBackup.migration_of(dst) }
    rescue SQLite3::Exception => e
      raise Error, "could not copy #{File.basename(src)}: #{e.message}"
    end

    def write_tar(name, work, files)
      primary = files.find { _1["file"] == "#{@rails_env}.sqlite3" }
      manifest = {
        "format" => FORMAT, "console_version" => @data_version, "made_by" => @version,
        "taken_at" => @now.iso8601, "rails_env" => @rails_env, "label" => @label,
        "migration" => primary&.dig("migration"), "code_migration" => ConsoleBackup.code_migration(@root),
        "databases" => files
      }
      partial = File.join(@backup_dir, ".#{name}.partial")
      File.open(partial, "wb", 0o600) do |io|
        Zlib::GzipWriter.wrap(io) do |gz|
          Gem::Package::TarWriter.new(gz) do |tar|
            body = JSON.pretty_generate(manifest) + "\n"
            tar.add_file_simple(MANIFEST, 0o644, body.bytesize) { _1.write(body) }
            files.each do |f|
              p = File.join(work, f["file"])
              tar.add_file_simple(f["file"], 0o600, File.size(p)) { |t| File.open(p, "rb") { |s| IO.copy_stream(s, t) } }
            end
          end
        end
      end
      final = File.join(@backup_dir, name)
      File.rename(partial, final)
      Entry.new(name, final, File.size(final), @now)
    ensure
      FileUtils.rm_f(partial) if partial && File.exist?(partial)
    end
  end

  # Restores one backup into the storage directory. Returns the notes to
  # print (warnings about versions); raises Error when it will not.
  class Restorer
    attr_reader :notes

    def initialize(storage:, backup_dir:, name:, version:, root:, force: false, rails_env: "production")
      @storage, @backup_dir, @name, @version, @root, @force, @rails_env = storage, backup_dir, name, version, root, force, rails_env
      @notes = []
    end

    def entry
      @entry ||= ConsoleBackup.list(@backup_dir).find { _1.name == @name } ||
        raise(Error, "no backup #{@name} in #{@backup_dir} (bin/asterism backups lists them)")
    end

    # Checks the versions; returns the notes (and raises when the backup is
    # from a newer console's migrations, unless forced).
    def check
      m = entry.manifest
      raise Error, "#{@name} is format #{m['format']}; this console reads format #{FORMAT}" unless m["format"] == FORMAT
      code = ConsoleBackup.code_migration(@root)
      current = File.join(@storage, "#{@rails_env}.sqlite3")
      have = File.exist?(current) ? ConsoleBackup.migration_of(current) : nil
      if m["console_version"] != @version
        @notes << "The backup holds console #{m['console_version']}'s data; this is console #{@version}."
      end
      if m["migration"].to_s > code
        msg = "The backup's databases have migration #{m['migration']}, newer than this console knows (#{code}): " \
              "console #{@version} cannot run on them. Restore with console #{m['console_version']}'s image."
        raise Error, msg unless @force
        @notes << "#{msg} (--force: restoring anyway)"
      end
      if have && have != m["migration"]
        @notes << "Restoring across a migration: the databases now have #{have}, the backup #{m['migration']}. " \
                  "Run console #{m['console_version']} with it (deploy/vps/update.sh #{m['console_version']}); " \
                  "a newer console migrates it again when it starts."
      end
      @notes
    end

    def run
      check
      ok = ConsoleBackup::Lock.try(@storage, :ex) { replace }
      return @notes if ok
      unless @force
        raise Error, "the console, the bridge or a backup is using #{@storage}. Stop them first:\n" \
                     "  docker compose stop console bridge backup\n" \
                     "then restore, then: docker compose start console bridge backup (or --force)"
      end
      @notes << "--force: restoring while something holds the databases"
      replace
      @notes
    end

    private

    def replace
      work = File.join(@storage, ".restore-#{Process.pid}")
      FileUtils.rm_rf(work)
      FileUtils.mkdir_p(work)
      extract(work)
      entry.manifest["databases"].each do |f|
        base = File.join(@storage, f["file"])
        FileUtils.rm_f([ base, "#{base}-wal", "#{base}-shm", "#{base}-journal" ])
        File.rename(File.join(work, f["file"]), base)
      end
    ensure
      FileUtils.rm_rf(work) if work
    end

    def extract(work)
      want = entry.manifest["databases"].to_h { [ _1["file"], _1 ] }
      Zlib::GzipReader.open(entry.path) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |e|
            next unless (f = want[e.full_name]) && !e.full_name.include?("/")
            File.open(File.join(work, e.full_name), "wb", 0o600) { IO.copy_stream(e, _1) }
          end
        end
      end
      want.each do |file, f|
        p = File.join(work, file)
        raise Error, "#{@name} lacks #{file}" unless File.exist?(p)
        raise Error, "#{file} in #{@name} does not match its checksum" unless Digest::SHA256.file(p).hexdigest == f["sha256"]
      end
    end
  end

  # The last outcome, in <backups>/status.json: written by every backup
  # (daily or by hand), read by the console for its warning.
  module Status
    module_function

    STALE = 50 * 3600 # a day and a bit more than one missed run

    def path(backup_dir) = File.join(backup_dir, STATUS)

    def read(backup_dir)
      JSON.parse(File.read(path(backup_dir)))
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      nil
    end

    def record(backup_dir, ok:, name: nil, error: nil, now: Time.now, **extra)
      s = read(backup_dir) || {}
      t = now.utc.iso8601(3) # a failure and a success in the same second stay ordered
      s["last_attempt_at"] = t
      if ok
        s.merge!("last_ok_at" => t, "last_ok_name" => name, "last_error" => nil, "last_error_at" => nil)
      else
        s.merge!("last_error" => error.to_s, "last_error_at" => t)
      end
      s.merge!(extra.transform_keys(&:to_s))
      FileUtils.mkdir_p(backup_dir)
      tmp = "#{path(backup_dir)}.tmp"
      File.write(tmp, JSON.pretty_generate(s) + "\n")
      File.rename(tmp, path(backup_dir))
      s
    rescue SystemCallError
      s # the status is a convenience; the backup's own outcome is what counts
    end

    # A warning for the console's admins, or nil when all is well (or when
    # no backup has run here at all: development, or a fresh server).
    # format: how a time is written (the console passes its time zone's).
    def warning(backup_dir, now: Time.now, format: ->(t) { t.utc.strftime("%Y-%m-%d %H:%M UTC") })
      s = read(backup_dir) or return nil
      ok_at = s["last_ok_at"] && Time.iso8601(s["last_ok_at"])
      err_at = s["last_error_at"] && Time.iso8601(s["last_error_at"])
      if err_at && (ok_at.nil? || err_at > ok_at)
        "The last backup failed (#{format.call(err_at)}): #{s['last_error']}"
      elsif ok_at && now - ok_at > STALE
        "No backup since #{format.call(ok_at)}: is the backup service running? (docker compose ps backup)"
      end
    rescue ArgumentError
      nil
    end
  end

  # The daily backup: the "backup" service runs this loop. Once a day at
  # ASTERISM_BACKUP_HOUR (the container's time zone, UTC unless TZ is set),
  # and once at start when the newest backup is more than a day old.
  class Daily
    def initialize(storage:, backup_dir:, rails_env:, version:, root:, hour:, keep:, out: $stdout, clock: -> { Time.now })
      @storage, @backup_dir, @rails_env, @version, @root = storage, backup_dir, rails_env, version, root
      @hour, @keep, @out, @clock = hour, keep, out, clock
    end

    # The next time the hour comes, after `now` (local time).
    def next_run(now = @clock.call)
      t = Time.new(now.year, now.month, now.day, @hour, 0, 0, now.utc_offset)
      t <= now ? t + 86_400 : t
    end

    def due_at_start?(now = @clock.call)
      newest = ConsoleBackup.list(@backup_dir).first
      newest.nil? || now - newest.time > 86_400
    end

    # One run: backup, rotation, status. Never raises (the loop goes on);
    # returns true when a backup was made.
    def run_once(label: "daily")
      e = Maker.new(storage: @storage, backup_dir: @backup_dir, rails_env: @rails_env, version: @version,
                    root: @root, label: label, now: @clock.call).run
      gone = ConsoleBackup.rotate(@backup_dir, keep: @keep)
      Status.record(@backup_dir, ok: true, name: e.name, now: @clock.call, next_at: next_run.utc.iso8601, keep: @keep)
      log "backup: made #{e.name} (#{e.bytes} bytes)#{"; deleted #{gone.join(', ')}" if gone.any?}"
      true
    rescue StandardError => e
      Status.record(@backup_dir, ok: false, error: e.message, now: @clock.call, next_at: next_run.utc.iso8601, keep: @keep)
      log "backup: FAILED: #{e.message}"
      false
    end

    def loop_forever(sleeper: ->(s) { sleep(s) })
      log "backup: daily at #{format('%02d:00', @hour)} (#{@clock.call.strftime('%Z')}), keeping #{@keep}, into #{@backup_dir}"
      run_once if due_at_start? && !ConsoleBackup.databases(@storage, @rails_env).empty?
      loop do
        at = next_run
        log "backup: next at #{at.iso8601}"
        while (left = at - @clock.call) > 0
          sleeper.call([ left, 600 ].min)
        end
        run_once
      end
    end

    private

    def log(text) = @out.puts("#{@clock.call.utc.iso8601} #{text}")
  end
end
