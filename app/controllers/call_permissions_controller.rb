# What the page may call. Admins see, add and remove rows (under /admin);
# everyone signed in may ask which rows cover one object (covering, JSON:
# the graph page greys out the methods nobody allowed).
class CallPermissionsController < ApplicationController
  require_admin except: %i[ covering ]
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

  def covering
    rows = CallPermission.order(:node, :app, :object, :method_name)
    rows = params[:path].present? ? CallPermission.for_path(params[:path], rows: rows) : []
    render json: rows.map(&:as_payload)
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
