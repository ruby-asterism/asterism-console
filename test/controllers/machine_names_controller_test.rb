require "test_helper"

class MachineNamesControllerTest < ActionDispatch::IntegrationTest
  MEMBERS = %w[/controller_manager /diff_drive_controller].freeze

  test "an admin names a machine, renames it and removes the name" do
    sign_in_as(users(:admin))
    assert_difference("MachineName.count", 1) do
      post machine_names_path, params: { name: "mujoco", members: MEMBERS }, as: :json
    end
    assert_response :created
    row = MachineName.last
    assert_equal [ "mujoco", MEMBERS, users(:admin) ], [ row.name, row.member_list, row.created_by ]
    patch machine_name_path(row), params: { name: "rover", members: MEMBERS + [ "/camera_jpeg" ] }, as: :json
    assert_response :ok
    assert_equal [ "rover", 3 ], [ row.reload.name, row.member_list.size ]
    assert_difference("MachineName.count", -1) { delete machine_name_path(row), as: :json }
  end

  test "a name without node names is refused" do
    sign_in_as(users(:admin))
    assert_no_difference("MachineName.count") { post machine_names_path, params: { name: "x", members: [] }, as: :json }
    assert_response :unprocessable_content
  end

  test "a user sees the names but cannot change them" do
    row = MachineName.create!(name: "mujoco", member_list: MEMBERS)
    sign_in_as(users(:user))
    get machine_names_path, as: :json
    assert_equal [ "mujoco" ], response.parsed_body.map { _1["name"] }
    assert_no_difference("MachineName.count") { post machine_names_path, params: { name: "x", members: MEMBERS }, as: :json }
    assert_response :forbidden
    patch machine_name_path(row), params: { name: "y" }, as: :json
    assert_response :forbidden
    assert_no_difference("MachineName.count") { delete machine_name_path(row), as: :json }
    assert_response :forbidden
  end

  test "the page knows whether the user may name machines" do
    sign_in_as(users(:user))
    get root_path
    assert_includes response.body, 'data-console-admin-value="false"'
    sign_in_as(users(:admin))
    get root_path
    assert_includes response.body, 'data-console-admin-value="true"'
  end
end
