require "test_helper"

class TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    FileUtils.rm_rf(FileTransfer.dir)
    # a member that receives files from the console (T4b), for two nodes
    @home = RelayPeer.create!(name: "home-a", kind: "router", nodes: "fmruby-abcdef\nfmruby-a", files_from_console: true)
  end

  teardown do
    FileUtils.rm_rf(FileTransfer.dir)
    FileUtils.rm_rf(@uploads) if @uploads
  end

  def upload(name = "hello.txt", body = "hello, machine\n")
    @uploads ||= Dir.mktmpdir("console-uploads")
    path = File.join(@uploads, name)
    File.binwrite(path, body)
    Rack::Test::UploadedFile.new(path, "application/octet-stream", original_filename: name)
  end

  test "a user sends a file to a node a file row allows: a pending row and the upload in the outbox" do
    sign_in_as(users(:user))
    get transfers_path
    assert_response :success
    assert_select "form#send-file"
    assert_select "#received", false # the received files are for admins
    assert_difference("FileTransfer.count", 1) do
      post transfers_path, params: { transfer: { file: upload, node: "fmruby-abcdef", overwrite: "1", sd: "0" } }
    end
    assert_redirected_to transfers_path
    r = FileTransfer.last
    assert_equal [ "send", "pending", "fmruby-abcdef", "hello.txt", 15, true, false, users(:user) ],
                 [ r.direction, r.status, r.node, r.name, r.size, r.overwrite, r.sd, r.user ]
    assert_equal Digest::SHA256.hexdigest("hello, machine\n"), r.sha256
    assert_equal "hello, machine\n", File.binread(r.outbox_path)
    # under another name, to the SD card
    post transfers_path, params: { transfer: { file: upload, node: "fmruby-abcdef", name: "renamed.txt", sd: "1" } }
    assert_equal [ "renamed.txt", true ], [ FileTransfer.last.name, FileTransfer.last.sd ]
  end

  test "a node no member's mark allows: a denied row, nothing uploaded" do
    sign_in_as(users(:user))
    assert_difference("FileTransfer.count", 1) do
      post transfers_path, params: { transfer: { file: upload, node: "linux-1" } }
    end
    r = FileTransfer.last
    assert_equal "denied", r.status
    assert_match(/no member row lets the console send files to linux-1/, flash[:alert])
    assert_nil r.outbox_path
    refute Dir.exist?(FileTransfer.outbox) && Dir.children(FileTransfer.outbox).any?
    # a call row does not let files go
    CallPermission.create!(node: "*", app: "*", object: "*", method_name: "*")
    post transfers_path, params: { transfer: { file: upload, node: "linux-1" } }
    assert_equal "denied", FileTransfer.last.status
    # nor a member that may only send to the console, nor a disabled one
    RelayPeer.create!(name: "linux-1", kind: "client", files_to_console: true)
    post transfers_path, params: { transfer: { file: upload, node: "linux-1" } }
    assert_equal "denied", FileTransfer.last.status
    @home.update!(enabled: false)
    post transfers_path, params: { transfer: { file: upload, node: "fmruby-abcdef" } }
    assert_equal "denied", FileTransfer.last.status
  end

  test "names and sizes a machine would refuse are refused here" do
    sign_in_as(users(:user))
    assert_no_difference("FileTransfer.count") do
      post transfers_path, params: { transfer: { file: upload, node: "fmruby-a", name: ".hidden" } }
      assert_match(/not a file name/, flash[:alert])
      post transfers_path, params: { transfer: { file: upload("x" * 49), node: "fmruby-a" } }
      post transfers_path, params: { transfer: { file: upload("empty.txt", ""), node: "fmruby-a" } }
      assert_equal "The file is empty.", flash[:alert]
      post transfers_path, params: { transfer: { node: "fmruby-a" } }
      assert_equal "Choose a file.", flash[:alert]
    end
  end

  test "the record: a user sees their own sends, an admin everything; cancel is the sender's" do
    mine = FileTransfer.create!(direction: "send", status: "sending", node: "fmruby-a", name: "a.txt", size: 3, user: users(:user))
    other = FileTransfer.create!(direction: "send", status: "sending", node: "fmruby-a", name: "b.txt", size: 3, user: users(:admin))
    got = FileTransfer.create!(direction: "receive", status: "done", node: "fmruby-a", name: "c.txt", size: 3)
    sign_in_as(users(:user))
    get transfers_path, as: :json
    assert_equal [ mine.id ], response.parsed_body.map { _1["id"] }
    get transfer_path(other), as: :json
    assert_response :not_found
    post cancel_transfer_path(other)
    assert_response :not_found
    post cancel_transfer_path(mine)
    assert_equal "cancelling", mine.reload.status
    sign_in_as(users(:admin))
    get transfers_path, as: :json
    assert_equal [ got.id, other.id, mine.id ], response.parsed_body.map { _1["id"] }
    get transfers_path
    assert_select "#transfer-records tr[data-transfer-id='#{got.id}']", /from/
  end

  test "the page's suggestions and its senders come from the members' marks (T4b)" do
    GraphState.current.update!(snapshot: JSON.generate("nodes" => [
      { "id" => "a_node:fmruby-abcdef", "kind" => "a_node", "label" => "fmruby-abcdef" },
      { "id" => "a_node:linux-1", "kind" => "a_node", "label" => "linux-1" }
    ], "edges" => []))
    sign_in_as(users(:admin))
    get transfers_path
    assert_select "#file-nodes option", 1
    assert_select "#file-nodes option[value=?]", "fmruby-abcdef"
    assert_select "#received p.hint", /Taken from:\s+nobody \(no member is marked/
    RelayPeer.create!(name: "linux-1", kind: "client", display_name: "Pi", files_to_console: true)
    @home.update!(files_to_console: true)
    get transfers_path
    assert_select "#received p.hint a", "Pi (linux-1)"
    assert_select "#received p.hint", /home-a \(for fmruby-abcdef, fmruby-a\)/
    assert_select "#file-nodes option", 1, "a mark to send to the console does not let the page send to it"
    @home.update!(files_from_console: false)
    get transfers_path
    assert_select "#file-nodes option", 0
    assert_select "p.hint", /No node may be sent files yet/
  end

  test "the received files: an admin lists, downloads and deletes them; a user cannot" do
    FileUtils.mkdir_p(FileTransfer.inbox)
    File.binwrite(FileTransfer.inbox.join("photo.bin"), "\x00\x01\x02".b)
    sign_in_as(users(:user))
    get received_transfers_path(name: "photo.bin")
    assert_redirected_to root_path
    sign_in_as(users(:admin))
    get transfers_path
    assert_select "#received a", "photo.bin"
    get received_transfers_path(name: "photo.bin")
    assert_response :success
    assert_equal "\x00\x01\x02".b, response.body.b
    get received_transfers_path(name: "../development.sqlite3")
    assert_response :not_found
    delete received_transfers_path(name: "photo.bin")
    refute File.exist?(FileTransfer.inbox.join("photo.bin"))
  end
end
