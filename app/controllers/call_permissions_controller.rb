# What the page may call. Everyone signed in sees the list (and the page
# asks which rows cover an object); only admins add or remove rows.
class CallPermissionsController < ApplicationController
  require_admin only: %i[ create destroy ]
  layout "plain"

  def index
    @rows = CallPermission.order(:node, :app, :object, :method_name)
    respond_to do |f|
      f.html { @row = CallPermission.new(node: "*", app: "*", object: "*", method_name: "") }
      f.json do
        rows = params[:path].present? ? CallPermission.for_path(params[:path], rows: @rows) : @rows
        render json: rows.map(&:as_payload)
      end
    end
  end

  def create
    @row = CallPermission.new(params.expect(call_permission: %i[ node app object method_name note ]))
    @row.created_by = current_user
    if @row.save
      redirect_to call_permissions_path, notice: "Allowed #{@row.path_pattern} #{@row.method_name}."
    else
      @rows = CallPermission.order(:node, :app, :object, :method_name)
      render :index, status: :unprocessable_content
    end
  end

  def destroy
    row = CallPermission.find(params[:id])
    row.destroy!
    redirect_to call_permissions_path, notice: "Removed #{row.path_pattern} #{row.method_name}.", status: :see_other
  end
end
