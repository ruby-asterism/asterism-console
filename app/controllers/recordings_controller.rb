# Recordings (V4, like rosbag and rqt_bag): start and stop a recording
# (the bridge writes it), list them, upload and download MCAP files, and
# the timeline of one (the JSON endpoints read the file with Bag::View).
#
# Any signed-in user may record, upload, look and download; stopping and
# deleting are for the one who started it, or an admin. Playing back onto
# the network is PlaybacksController (admins only).
class RecordingsController < ApplicationController
  before_action :set_recording, except: %i[index create upload]
  before_action :require_owner, only: %i[stop destroy]
  before_action :require_file, only: %i[download ticks message fields series graph structure]

  def index
    @recordings = Recording.includes(:user).newest_first.limit(200).to_a
    @topics = ros_topics
    respond_to do |f|
      f.html
      f.json { render json: @recordings.map(&:as_payload) }
    end
  end

  def create
    p = params.fetch(:recording, {}).permit(:name, :keys, :structure, :max_mb, :max_seconds, topics: [])
    rec = Recording.new(user: current_user, source: "recorded", status: "pending", name: p[:name])
    rec.selection_value = { "topics" => Array(p[:topics]).compact_blank, "keys" => p[:keys].to_s.split(/[\r\n,]+/),
                            "structure" => p[:structure] }
    rec.max_bytes = (Float(p[:max_mb], exception: false) || Recording::DEFAULT_MAX_BYTES / Recording::MB) * Recording::MB
    rec.max_seconds = Integer(p[:max_seconds].presence || Recording::DEFAULT_MAX_SECONDS, exception: false) || 0
    if rec.save
      respond_to do |f|
        f.html { redirect_to recording_path(rec), notice: "Recording started (the bridge picks it up within a second)." }
        f.json { render json: rec.as_payload, status: :created }
      end
    else
      respond_to do |f|
        f.html { redirect_to recordings_path, alert: rec.errors.full_messages.join(", ") }
        f.json { render json: { "errors" => rec.errors.full_messages }, status: :unprocessable_content }
      end
    end
  end

  def show
    respond_to do |f|
      f.html do
        @info = @recording.finished? ? timeline_info : nil
        @can_play = current_user.admin?
        render @recording.finished? ? "timeline" : "progress", layout: @recording.finished? ? "application" : "plain"
      end
      f.json { render json: @recording.as_payload.merge("info" => @recording.finished? ? safe_info : nil) }
    end
  end

  def stop
    @recording.stop!
    respond_to do |f|
      f.html { redirect_to recording_path(@recording) }
      f.json { render json: @recording.as_payload }
    end
  end

  def destroy
    if @recording.active?
      return redirect_to(recording_path(@recording), alert: "Stop the recording first.")
    end
    Bag::View.forget(@recording.path)
    @recording.destroy!
    redirect_to recordings_path, notice: "Deleted #{@recording.name}."
  end

  # An MCAP file (rosbag2, Foxglove, or one of the console's) to look at.
  def upload
    file = params[:file]
    return redirect_to(recordings_path, alert: "Choose an .mcap file.") unless file.respond_to?(:path)
    if file.size > Recording::MAX_UPLOAD
      return redirect_to(recordings_path, alert: "The file is over #{Recording::MAX_UPLOAD / Recording::MB} MB.")
    end
    if Recording.total_bytes + file.size > Recording::MAX_TOTAL
      return redirect_to(recordings_path, alert: "The recordings take #{Recording::MAX_TOTAL / Recording::MB} MB already.")
    end
    rec = Recording.new(user: current_user, source: "uploaded", status: "uploaded",
                        name: File.basename(file.original_filename.to_s).truncate(120),
                        max_bytes: Recording::LIMIT_MAX_BYTES, max_seconds: Recording::LIMIT_MAX_SECONDS)
    rec.valid? # the file name
    FileUtils.mkdir_p(Recording.dir)
    FileUtils.cp(file.path, rec.path)
    begin
      info = MCAP::Reader.new(rec.path.to_s).then { |r| r.info.tap { r.close } }
    rescue MCAP::Error => e
      FileUtils.rm_f(rec.path)
      return redirect_to(recordings_path, alert: "Not a readable MCAP file: #{e.message}")
    end
    rec.assign_attributes(info: JSON.generate(info), messages: info["messages"], bytes: File.size(rec.path),
                          duration_s: info["duration_ns"] / 1e9, started_at: Time.current, finished_at: Time.current)
    rec.save!
    redirect_to recording_path(rec), notice: "Uploaded #{rec.name}."
  end

  # The file; ?ros2=1: a copy with only the ROS 2 topics (what `ros2 bag
  # play` accepts: it refuses a file that mixes serialization formats).
  def download
    base = @recording.name.sub(/\.mcap\z/i, "").parameterize.presence || "recording"
    if params[:ros2].present?
      # Made once per recording (tmp/exports, out of git), again when the
      # recording's file is newer.
      out = Rails.root.join("tmp/exports", @recording.filename.sub(/\.mcap\z/, "-ros2.mcap"))
      unless File.file?(out) && File.mtime(out) >= File.mtime(@recording.path)
        FileUtils.mkdir_p(out.dirname)
        File.open("#{out}.part", "wb") { |f| Bag::Copy.ros2_only(@recording.path, f) }
        File.rename("#{out}.part", out)
      end
      send_file out, filename: "#{base}-ros2.mcap", type: "application/octet-stream"
    else
      send_file @recording.path, filename: "#{base}.mcap", type: "application/octet-stream"
    end
  end

  # The pages give and get times as nanoseconds from the recording's first
  # message (t, and log_time / prev / next / at in the answers): absolute
  # nanoseconds since the epoch do not fit a JavaScript number exactly, and
  # stepping to the next message needs its exact time.
  def ticks
    view_json do |v|
      tk = v.ticks(params[:buckets].presence || 600)
      { "start" => v.start_ns.to_s, "span" => v.end_ns && v.start_ns ? v.end_ns - v.start_ns : 0,
        "buckets" => tk["buckets"], "channels" => tk["channels"] }
    end
  end

  # ?channel=<id>&t=<offset ns>: that channel's message at t; ?t= alone: every channel's.
  def message
    view_json do |v|
      t = abs_time(v)
      if params[:channel].present?
        m = v.message(params[:channel], t) or next({ "error" => "no message on that channel" })
        relative(v, m, %w[log_time prev next]).merge("publish_time" => m["publish_time"].to_s,
                                                     "publish_offset" => m["publish_time"] && m["publish_time"] - v.start_ns.to_i)
      else
        { "at" => v.at(t).transform_values { |m| m && relative(v, m, %w[log_time]) } }
      end
    end
  end

  def fields
    view_json { |v| { "fields" => v.fields(params[:channel]) } }
  end

  # ?channel=<id>&paths[]=linear.x
  def series
    paths = Array(params[:paths]).map(&:to_s).first(StreamLease::MAX_FIELDS)
    view_json { |v| v.series(params[:channel], paths) }
  end

  # The network structure at ?t=<ns> (JSON).
  def graph
    view_json do |v|
      g = v.graph_at(abs_time(v))
      g ? relative(v, g, %w[at prev next]) : { "error" => "this recording has no network structure" }
    end
  end

  # The graph rewind page.
  def structure
    @view = Bag::View.open(@recording.path)
    @changes = @view.graph_changes.map { _1.merge("at" => _1["at"] - @view.start_ns.to_i) }
    render layout: "application"
  end

  private

  def set_recording
    @recording = Recording.find(params[:id])
  end

  def require_owner
    return if @recording.owned_by?(current_user)
    respond_to do |f|
      f.html { redirect_to recording_path(@recording), alert: "Only the one who started it, or an admin, can do that." }
      f.json { render json: { "errors" => [ "not yours" ] }, status: :forbidden }
    end
  end

  def require_file
    return if @recording.finished? && @recording.file?
    respond_to do |f|
      f.html { redirect_to recording_path(@recording), alert: "The recording is not finished." }
      f.json { render json: { "errors" => [ "the recording is not finished" ] }, status: :conflict }
    end
  end

  def abs_time(v)
    v.start_ns.to_i + (Integer(params[:t].to_s, exception: false) || 0)
  end

  def relative(v, h, keys)
    keys.each { |k| h = h.merge(k => h[k] && h[k] - v.start_ns.to_i) }
    h
  end

  def view_json
    render json: yield(Bag::View.open(@recording.path))
  rescue MCAP::UnsupportedCompression => e
    render json: { "error" => e.message, "compression" => e.compression }, status: :unprocessable_content
  rescue MCAP::Error, ArgumentError => e
    render json: { "error" => e.message }, status: :unprocessable_content
  end

  # The file's info with the channels as the timeline sees them (their kind).
  def timeline_info
    info = safe_info
    return info if info["error"]
    info.merge("channels" => Bag::View.open(@recording.path).channels)
  rescue MCAP::Error, SystemCallError => e
    { "error" => e.message, "channels" => [] }
  end

  def safe_info
    @recording.read_info!
  rescue MCAP::Error, SystemCallError => e
    { "error" => e.message, "channels" => [] }
  end

  def ros_topics
    GraphState.current.graph["nodes"].select { _1["kind"] == "r_topic" }.map do |n|
      { "id" => n["id"], "name" => n["data"]["name"], "type" => n["data"]["type"], "domain" => n["data"]["domain"] }
    end.sort_by { [ _1["domain"].to_s, _1["name"].to_s ] }
  end
end
