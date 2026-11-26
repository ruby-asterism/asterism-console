require "test_helper"

# The remote shell's files on Rails' side (docs/terminal.md, "Files: get
# and put"): put's upload (the page open, in a machine, the user's
# permission, the console's limits) and get's download (its user only,
# once, not after KEEP), and the line of a put carrying its upload.
class TerminalFilesControllerTest < ActionDispatch::IntegrationTest
  PAGE = "page-ffffffffffffffff"

  setup do
    @dir = Dir.mktmpdir("rshell_files")
    ENV["ASTERISM_RSHELL_FILES_DIR"] = @dir
    sign_in_as(users(:user))
    post lease_terminal_path, params: { page: PAGE }, as: :json
    TerminalSession.set_remote(PAGE, { "node" => "fmruby-aaaaaa", "commands" => { "ls" => "read" }, "cwd" => "/home",
                                       "rshell" => 3 })
    users(:user).update!(rshell_access: "write")
  end

  teardown do
    FileUtils.rm_rf(@dir)
    ENV.delete("ASTERISM_RSHELL_FILES_DIR")
  end

  def file(name, data)
    path = File.join(@dir, "src-#{SecureRandom.hex(4)}")
    File.binwrite(path, data)
    Rack::Test::UploadedFile.new(path, "application/octet-stream", true, original_filename: name)
  end

  test "put's upload: the files kept for the user, then the line carries the token" do
    post uploads_terminal_path, params: { page: PAGE, files: [ file("a.bin", "\x00\xff".b), file("かな.txt", "k") ] }
    assert_response :created
    token = response.parsed_body["upload"]
    files = TerminalFiles.put_files(token, users(:user))
    assert_equal [ [ "a.bin", 2 ], [ "かな.txt", 1 ] ], files.map { [ _1["name"], _1["size"] ] }
    assert_equal "\x00\xff".b, File.binread(files[0]["path"])
    assert_nil TerminalFiles.put_files(token, users(:admin)), "another user's"
    post commands_terminal_path, params: { page: PAGE, line: "put", cols: 80, remote: "fmruby-aaaaaa", upload: token }, as: :json
    assert_response :created
    row = TerminalCommand.find(response.parsed_body["id"])
    assert_equal [ "put", "write", "write_begin", token ], [ row.command, row.effect, row.method_name, row.files_value["upload"] ]
  end

  test "put's upload is refused: a read-only user, a page in no machine, a page not open, no file, two of a name" do
    users(:user).update!(rshell_access: "read")
    post uploads_terminal_path, params: { page: PAGE, files: [ file("a", "a") ] }
    assert_response :forbidden
    assert_match(/you may only read/, response.parsed_body["error"])
    users(:user).update!(rshell_access: "write")
    post uploads_terminal_path, params: { page: PAGE }
    assert_response :unprocessable_content
    assert_match(/choose a file/, response.parsed_body["error"])
    post uploads_terminal_path, params: { page: PAGE, files: [ file("a", "a"), file("a", "b") ] }
    assert_match(/two files are named a/, response.parsed_body["error"])
    post uploads_terminal_path, params: { page: "page-notopennotopennot", files: [ file("a", "a") ] }
    assert_response :forbidden
    TerminalSession.set_remote(PAGE, nil)
    post uploads_terminal_path, params: { page: PAGE, files: [ file("a", "a") ] }
    assert_response :conflict
  end

  test "put's upload over the console's limit" do
    stub_const(TerminalFiles, :FILE_MAX, 3) do
      post uploads_terminal_path, params: { page: PAGE, files: [ file("big", "abcd") ] }
    end
    assert_response :unprocessable_content
    assert_match(/big: over 0 MB/, response.parsed_body["error"])
  end

  test "get's download: its user, once" do
    token, path = TerminalFiles.new_get(user_id: users(:user).id, page: PAGE, node: "fmruby-aaaaaa", name: "pic.png", size: 3)
    File.binwrite(path, "\x89PN".b)
    sign_in_as(users(:admin))
    get file_terminal_path(token)
    assert_response :not_found
    sign_in_as(users(:user))
    get file_terminal_path(token)
    assert_response :success
    assert_equal "\x89PN".b, response.body.b
    assert_match(/attachment; filename="pic.png"/, response.headers["Content-Disposition"])
    get file_terminal_path(token)
    assert_response :not_found
  end

  test "what nobody takes goes after KEEP" do
    token, path = TerminalFiles.new_get(user_id: users(:user).id, page: PAGE, node: "n", name: "x", size: 1)
    File.binwrite(path, "x")
    assert_equal 0, TerminalFiles.sweep
    assert_equal 1, TerminalFiles.sweep(Time.now.to_f + TerminalFiles::KEEP + 1)
    get file_terminal_path(token)
    assert_response :not_found
  end

  private

  def stub_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end
end
