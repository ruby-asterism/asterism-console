# Keys whose values the page shows as they arrive. The bridge subscribes
# to every row.
class WatchesController < ApplicationController
  def index
    render json: Watch.order(:id).map(&:as_payload)
  end

  def create
    w = Watch.find_or_initialize_by(key: params[:key].to_s.strip)
    if w.save
      ConsoleChannel.send_message("watch", "watch" => w.as_payload)
      render json: w.as_payload, status: :created
    else
      render json: { "errors" => w.errors.full_messages }, status: :unprocessable_content
    end
  end

  def destroy
    w = Watch.find(params[:id])
    w.destroy!
    ConsoleChannel.send_message("unwatch", "watch" => w.as_payload)
    head :no_content
  end
end
