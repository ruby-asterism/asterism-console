class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :rooms_visible?

  private

  # Whether this user, from this address, sees the rooms in the graph
  # (admins only, docs/rooms.md).
  def rooms_visible?
    ConsoleAdmin.rooms_visible?(current_user, request.remote_ip)
  end
end
