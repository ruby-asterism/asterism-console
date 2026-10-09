# The call log: who asked for what, when, and the answer (BridgeRequest
# rows, newest first). Calls by default; ?all=1 also shows the meta reads.
# Below them, the playbacks to the network (Playback rows, V4): traffic the
# console put on the network, by whom.
class CallsController < ApplicationController
  LIMIT = 200
  layout "plain"

  def index
    scope = BridgeRequest.includes(:user).order(id: :desc).limit(LIMIT)
    scope = scope.where(kind: "call") unless params[:all].present?
    @rows = scope.to_a
    @playbacks = Playback.includes(:user).order(id: :desc).limit(LIMIT).to_a
    respond_to do |f|
      f.html
      f.json { render json: @rows.map(&:as_payload) }
    end
  end
end
