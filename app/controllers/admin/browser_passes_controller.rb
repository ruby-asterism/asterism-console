module Admin
  # Every user's passes for the browser build (W4), newest first.
  class BrowserPassesController < ApplicationController
    require_admin
    layout "plain"

    def index
      @passes = BrowserPass.includes(:user, :revoked_by).order(id: :desc).limit(200)
    end
  end
end
