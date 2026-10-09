# The log page (like rqt_console): /rosout of the ROS 2 nodes and the
# Asterism log keys, filtered in the page. The bridge decodes
# (Bridge::Logs); nothing is kept on the server.
class LogsController < ApplicationController
  include StreamLeasing

  def show
    @node = params[:node].to_s[0, 200]
  end

  private
    def lease_kind = "log"
end
