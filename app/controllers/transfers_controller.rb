# Files (T4, docs/files.md): send a file from the browser to a machine,
# the files the machines sent to the console, and the record of both.
#
# Sending is for every signed-in user, to the nodes a call permission of
# kind "file" names (Admin > Call permissions); the page uploads the file,
# the bridge sends it (FileTransfer). A user sees and cancels their own
# sends; an admin everyone's. The received files and their records are for
# admins only (like the recordings, W4: they hold whatever the machines
# sent).
class TransfersController < ApplicationController
  LIMIT = 200
  layout "plain"
  require_admin only: %i[ received destroy_received ]
  before_action :set_transfer, only: %i[ show cancel ]

  def index
    scope = FileTransfer.includes(:user).newest_first.limit(LIMIT)
    scope = scope.where(direction: "send", user: current_user) unless current_user.admin?
    @rows = scope.to_a
    respond_to do |f|
      f.html do
        @nodes = file_nodes
        @received = current_user.admin? ? FileTransfer.received_files : []
        @any_file_rule = CallPermission.files.exists?
      end
      f.json { render json: @rows.map(&:as_payload) }
    end
  end

  def show
    render json: @transfer.as_payload
  end

  def create
    p = params.fetch(:transfer, {}).permit(:node, :name, :overwrite, :sd, :file)
    file = p[:file]
    return refuse("Choose a file.") unless file.respond_to?(:path)
    node = p[:node].to_s.strip
    name = p[:name].to_s.strip.presence || File.basename(file.original_filename.to_s)
    name = name.dup.force_encoding(Encoding::UTF_8)
    row = FileTransfer.new(direction: "send", status: "pending", user: current_user, node: node, name: name,
                           size: file.size, overwrite: truthy?(p[:overwrite]), sd: truthy?(p[:sd]))
    return refuse(row.errors.full_messages.to_sentence) unless row.valid?
    return refuse("The file is empty.") if file.size.zero?
    return refuse("The file is over #{FileTransfer::MAX_UPLOAD / FileTransfer::MB} MB.") if file.size > FileTransfer::MAX_UPLOAD
    unless CallPermission.allows_file?(node)
      row.assign_attributes(status: "denied", reason: "no call permission lets the page send files to #{node}",
                            finished_at: Time.current)
      row.save!
      return refuse(row.reason)
    end
    if FileTransfer.sends.active.count >= FileTransfer::MAX_PENDING
      return refuse("#{FileTransfer::MAX_PENDING} files are on their way already.")
    end
    row.stored = SecureRandom.hex(12)
    FileUtils.mkdir_p(FileTransfer.outbox)
    FileUtils.cp(file.path, row.outbox_path)
    row.sha256 = Digest::SHA256.file(row.outbox_path).hexdigest
    row.save!
    respond_to do |f|
      f.html { redirect_to transfers_path, notice: "Sending #{row.name} to #{row.node} (the bridge takes it within a second)." }
      f.json { render json: row.as_payload, status: :created }
    end
  end

  def cancel
    return head(:forbidden) unless @transfer.sending? && @transfer.owned_by?(current_user)
    @transfer.cancel!
    respond_to do |f|
      f.html { redirect_to transfers_path, status: :see_other }
      f.json { render json: @transfer.as_payload }
    end
  end

  # A received file (?name=).
  def received
    path = FileTransfer.received_path(params[:name])
    return head(:not_found) unless path
    send_file path, filename: File.basename(path), type: "application/octet-stream"
  end

  def destroy_received
    path = FileTransfer.received_path(params[:name])
    return redirect_to(transfers_path, alert: "No such file.", status: :see_other) unless path
    File.delete(path)
    redirect_to transfers_path, notice: "Deleted #{File.basename(path)} (its record stays).", status: :see_other
  end

  private

  def set_transfer
    @transfer = FileTransfer.find(params[:id])
    head(:not_found) unless current_user.admin? || (@transfer.sending? && @transfer.user_id == current_user.id)
  end

  def refuse(why)
    respond_to do |f|
      f.html { redirect_to transfers_path, alert: why, status: :see_other }
      f.json { render json: { "errors" => [ why ] }, status: :unprocessable_content }
    end
  end

  def truthy?(v) = [ true, "1", "true", "on" ].include?(v)

  # The Asterism nodes on the network now that a "file" row lets the page
  # send to (the form's suggestions), this console's own left out.
  def file_nodes
    rows = CallPermission.files.to_a
    own = GraphState.current.info["node"]
    GraphState.current.graph["nodes"].filter_map do |n|
      next unless n["kind"] == "a_node"
      id = n.dig("data", "node") || n["label"]
      id if id.is_a?(String) && id != own && CallPermission.allows_file?(id, rows: rows)
    end.uniq.sort
  rescue JSON::ParserError
    []
  end
end
