# The whole graph now (the page asks for it when it missed a diff).
class GraphsController < ApplicationController
  def show
    render json: GraphState.current.as_payload
  end
end
