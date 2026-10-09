# Playback of a recording onto the network (V4): admins only, and only
# with confirm=inject (the page asks first), because it puts traffic on the
# network that other nodes act on. The bridge does the sending
# (Bridge::Player); the rows are the audit log (the call log page lists them).
class PlaybacksController < ApplicationController
  require_admin only: %i[create stop]

  def create
    unless params[:confirm] == "inject"
      return render json: { "errors" => [ "playing to the network needs confirm=inject (it injects traffic)" ] },
                    status: :unprocessable_content
    end
    rec = Recording.find_by(id: params[:recording_id])
    pb = Playback.new(user: current_user, recording: rec, speed: Float(params[:speed].to_s, exception: false) || 1.0,
                      start_ns: Integer(params[:start_ns].to_s, exception: false))
    pb.channel_ids = Array(params[:channels]).compact_blank
    if pb.save
      render json: pb.as_payload, status: :created
    else
      render json: { "errors" => pb.errors.full_messages }, status: :unprocessable_content
    end
  end

  def show
    render json: Playback.find(params[:id]).as_payload
  end

  def stop
    pb = Playback.find(params[:id])
    pb.stop!
    render json: pb.as_payload
  end
end
