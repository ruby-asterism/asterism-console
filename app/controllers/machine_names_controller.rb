# The names of machines of ROS 2 nodes (V2.3), given from the details of a
# group in the graph. Everyone signed in sees them (in the graph); only
# admins give, change or remove one, as with the call permissions and the
# relay registry (W2): a name is shared by every user of the console.
#
# The page sends the name and the group's ROS 2 node names now; the bridge
# reads the names with the admin space and the graph shows them within a
# few seconds.
class MachineNamesController < ApplicationController
  require_admin only: %i[ create update destroy ]

  def index
    render json: MachineName.order(:id).map(&:as_payload)
  end

  def create
    row = MachineName.new(name: params[:name], created_by: current_user)
    row.member_list = params[:members]
    save(row, :created)
  end

  # A new name for the same machine; the node names are taken again (the
  # group as it is now).
  def update
    row = MachineName.find(params[:id])
    row.name = params[:name]
    row.member_list = params[:members] if params.key?(:members)
    save(row, :ok)
  end

  def destroy
    MachineName.find(params[:id]).destroy!
    head :no_content
  end

  private

  def save(row, status)
    if row.save
      render json: row.as_payload, status: status
    else
      render json: { "errors" => row.errors.full_messages }, status: :unprocessable_content
    end
  end
end
