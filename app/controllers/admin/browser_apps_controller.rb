module Admin
  # The apps "Launch Web Studio" may start (0.3.12, BrowserApp): an admin
  # adds, changes and removes them. Make a pass offers "Nothing" and these,
  # and open takes nothing else; the rooms' page offers them too (after
  # ASTERISM_ROOM_APPS). Before 0.3.12 each role named one.
  class BrowserAppsController < ApplicationController
    require_admin
    layout "plain"
    before_action :set_app, only: %i[edit update destroy]

    def index
      @apps = BrowserApp.in_order
      @app = BrowserApp.new
    end

    def create
      @app = BrowserApp.new(app_params)
      if @app.save
        Rails.logger.info("studio apps: #{current_user.log_name} added #{@app.path}")
        redirect_to admin_browser_apps_path, status: :see_other, notice: "Added #{@app.path}."
      else
        @apps = BrowserApp.in_order
        render :index, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @app.update(app_params)
        Rails.logger.info("studio apps: #{current_user.log_name} changed #{@app.id} to #{@app.path}")
        redirect_to admin_browser_apps_path, status: :see_other, notice: "Saved #{@app.path}."
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Passes already made for it keep it (BrowserPass#app); it is no longer
    # offered.
    def destroy
      @app.destroy!
      Rails.logger.info("studio apps: #{current_user.log_name} removed #{@app.path}")
      redirect_to admin_browser_apps_path, status: :see_other, notice: "Removed #{@app.path}."
    end

    private

    def set_app
      @app = BrowserApp.find(params[:id])
    end

    def app_params
      params.expect(browser_app: %i[label path position])
    end
  end
end
