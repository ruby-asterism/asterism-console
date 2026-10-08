# The one page: the graph, the details of the selected node, the watched
# keys. Everything after the first render comes over Action Cable.
class ConsoleController < ApplicationController
  def show
    @state = GraphState.current
    @watches = Watch.order(:id)
  end
end
