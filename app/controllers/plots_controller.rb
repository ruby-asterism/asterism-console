# The plot page (like rqt_plot): numeric fields of ROS 2 topics and
# Asterism keys over time. The bridge decodes and decimates
# (Bridge::Plots); the page draws (uPlot).
class PlotsController < ApplicationController
  include StreamLeasing

  def show
    @topics = ros_topics
    @topic = params[:topic].to_s
  end

  private
    def lease_kind = "plot"

    # The ROS 2 topics on the network now, for the picker.
    def ros_topics
      GraphState.current.graph["nodes"].select { _1["kind"] == "r_topic" }.map do |n|
        { "id" => n["id"], "name" => n["data"]["name"], "type" => n["data"]["type"], "domain" => n["data"]["domain"] }
      end.sort_by { [ _1["domain"].to_s, _1["name"].to_s ] }
    end
end
