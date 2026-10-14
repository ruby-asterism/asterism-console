module ApplicationCable
  # The WebSocket takes the same signed cookie as the pages: without a
  # signed-in user the connection is refused, so the graph, the answers and
  # the watched values reach signed-in browsers only.
  class Connection < ActionCable::Connection::Base
    # remote_ip: where the browser is (the graph's rooms are for admins on
    # the admin networks, ConsoleAdmin.rooms_visible?).
    identified_by :current_user, :remote_ip

    def connect
      set_current_user || reject_unauthorized_connection
      self.remote_ip = request.remote_ip
    end

    private
      def set_current_user
        if (session = Session.live(cookies.signed[:session_id]))
          self.current_user = session.user
        end
      end
  end
end
