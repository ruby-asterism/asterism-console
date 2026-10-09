module ApplicationCable
  # The WebSocket takes the same signed cookie as the pages: without a
  # signed-in user the connection is refused, so the graph, the answers and
  # the watched values reach signed-in browsers only.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      def set_current_user
        if (session = Session.live(cookies.signed[:session_id]))
          self.current_user = session.user
        end
      end
  end
end
