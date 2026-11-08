# What the page may call, and (kind "file", T4) which nodes it may send
# files to. Admins see, add and remove rows (under /admin);
# everyone signed in may ask which rows cover one object (covering, JSON:
# the graph page greys out the methods nobody allowed).
class CallPermissionsController < ApplicationController
  require_admin except: %i[ covering ]
  layout "plain"

  def index
    @rows = CallPermission.order(:kind, :node, :app, :object, :method_name)
    respond_to do |f|
      f.html do
        @row = CallPermission.new(node: "*", app: "*", object: "*", method_name: "")
        @file_row = CallPermission.new(kind: "file", node: "")
      end
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
    @row = CallPermission.new(params.expect(call_permission: %i[ kind node app object method_name note ]))
    @row.kind = "call" if @row.kind.blank?
    @row.created_by = current_user
    if @row.save
      redirect_to call_permissions_path, notice: "Allowed #{describe(@row)}."
    else
      @rows = CallPermission.order(:kind, :node, :app, :object, :method_name)
      if @row.kind == "file"
        @file_row = @row
        @row = CallPermission.new(node: "*", app: "*", object: "*", method_name: "")
      else
        @file_row = CallPermission.new(kind: "file", node: "")
      end
      render :index, status: :unprocessable_content
    end
  end

  def destroy
    row = CallPermission.find(params[:id])
    row.destroy!
    redirect_to call_permissions_path, notice: "Removed #{describe(row)}.", status: :see_other
  end

  private

  def describe(row)
    row.kind == "file" ? "sending files to #{row.node}" : "#{row.path_pattern} #{row.method_name}"
  end
end
