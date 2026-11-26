# The files of the remote shell's get and put (docs/terminal.md, "Files:
# get and put"), held by the console for a moment on their way between a
# browser and a machine. Plain files, no table:
#
#   <dir>/get/<token>/meta.json, data   a file brought from a machine by the
#                                       bridge, for the user who asked to take
#                                       once (TerminalsController#download)
#   <dir>/put/<token>/meta.json, 0 1 ..  the files a page chose for put,
#                                       uploaded by Rails, sent by the bridge
#
# meta.json: {"user_id", "page", "at" (epoch seconds), ...} and for get
# {"node", "name", "size"}, for put {"files" => [{"name", "size"}]}. A token
# is 32 hex digits and only its user may use it. What is not taken (a get
# not downloaded, a put not sent) goes after KEEP; a get downloaded goes at
# once, a put sent when the bridge is done with it.
module TerminalFiles
  MB = 1024 * 1024
  # The largest file get brings or put sends (the plan's 16 MB).
  FILE_MAX = Integer(ENV.fetch("ASTERISM_RSHELL_FILE_MAX_BYTES", 16 * MB))
  # Files one put takes at most.
  MAX_FILES = 16
  # How long a file waits to be taken.
  KEEP = Integer(ENV.fetch("ASTERISM_RSHELL_FILE_KEEP_SECONDS", 600))
  TOKEN = /\A[0-9a-f]{32}\z/

  module_function

  def dir
    Pathname(ENV.fetch("ASTERISM_RSHELL_FILES_DIR", Rails.root.join("storage/rshell_files").to_s))
  end

  def get_dir = dir.join("get")
  def put_dir = dir.join("put")

  # A name a file may have on the machine: one part of a path, UTF-8.
  def file_name?(name)
    name.is_a?(String) && name.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !name.empty? &&
      name.bytesize <= 255 && name != "." && name != ".." && name.each_byte.none? { |c| c < 32 || c == 127 || c == 47 }
  end

  # ---- get ----

  # A place for a file the bridge brings: [token, the path to write].
  def new_get(user_id:, page:, node:, name:, size:)
    token = SecureRandom.hex(16)
    d = get_dir.join(token)
    FileUtils.mkdir_p(d)
    write_meta(d, "user_id" => user_id, "page" => page, "node" => node, "name" => name, "size" => size)
    [ token, d.join("data") ]
  end

  # The file of token for user, once: {"name", "data"} (the place is gone
  # after), or nil.
  def take_get(token, user)
    d = place(get_dir, token, user) or return nil
    m = read_meta(d)
    data = File.binread(d.join("data"))
    FileUtils.rm_rf(d)
    { "name" => m["name"].to_s, "data" => data }
  rescue Errno::ENOENT
    FileUtils.rm_rf(d) if d
    nil
  end

  def drop_get(token)
    FileUtils.rm_rf(get_dir.join(token)) if TOKEN.match?(token.to_s)
  end

  # ---- put ----

  # The files a page chose (uploaded files: original_filename, path, size).
  # Returns the token, or raises ArgumentError with the reason.
  def new_put(user_id:, page:, files:)
    files = Array(files)
    raise ArgumentError, "choose a file" if files.empty?
    raise ArgumentError, "at most #{MAX_FILES} files at a time" if files.size > MAX_FILES
    list = files.map do |f|
      name = File.basename(f.original_filename.to_s).dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "#{name.inspect}: not a name for a file on the machine" unless file_name?(name)
      raise ArgumentError, "#{name}: over #{FILE_MAX / MB} MB (the console's limit)" if f.size > FILE_MAX
      { "name" => name, "size" => f.size }
    end
    dups = list.map { _1["name"] }.tally.select { |_, n| n > 1 }.keys
    raise ArgumentError, "two files are named #{dups.first}" if dups.any?
    token = SecureRandom.hex(16)
    d = put_dir.join(token)
    FileUtils.mkdir_p(d)
    files.each_with_index { |f, i| FileUtils.cp(f.path, d.join(i.to_s)) }
    write_meta(d, "user_id" => user_id, "page" => page, "files" => list)
    token
  end

  # The files of token for user: [{"name", "size", "path"}], or nil.
  def put_files(token, user)
    d = place(put_dir, token, user) or return nil
    Array(read_meta(d)["files"]).each_with_index.map do |f, i|
      { "name" => f["name"].to_s, "size" => f["size"].to_i, "path" => d.join(i.to_s).to_s }
    end
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def drop_put(token)
    FileUtils.rm_rf(put_dir.join(token)) if TOKEN.match?(token.to_s)
  end

  # ---- both ----

  # Removes what waited past KEEP (and what has no meta). Returns how many.
  def sweep(now = Time.now.to_f)
    n = 0
    [ get_dir, put_dir ].each do |base|
      next unless File.directory?(base)
      Dir.children(base).each do |t|
        d = base.join(t)
        at = begin
          read_meta(d)["at"].to_f
        rescue Errno::ENOENT, JSON::ParserError
          File.mtime(d).to_f - KEEP + 60 # a place being made: a minute
        end
        next if now - at < KEEP
        FileUtils.rm_rf(d)
        n += 1
      end
    end
    n
  end

  def place(base, token, user)
    return nil unless TOKEN.match?(token.to_s) && user
    d = base.join(token.to_s)
    return nil unless File.directory?(d)
    m = read_meta(d)
    return nil unless m["user_id"] == user_id_of(user)
    if Time.now.to_f - m["at"].to_f >= KEEP
      FileUtils.rm_rf(d)
      return nil
    end
    d
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def user_id_of(user) = user.respond_to?(:id) ? user.id : user

  def write_meta(d, h)
    File.write(d.join("meta.json.part"), JSON.generate(h.merge("at" => Time.now.to_f)))
    File.rename(d.join("meta.json.part"), d.join("meta.json"))
  end

  def read_meta(d) = JSON.parse(File.read(d.join("meta.json")))
end
