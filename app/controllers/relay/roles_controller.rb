module Relay
  # Roles of the relay registry (G1.5): a name and key templates; rows of
  # the registry pick them. Admins only (under /admin).
  class RolesController < ApplicationController
    require_admin
    before_action :set_role, only: %i[ show edit update destroy ]
    layout "plain"

    def index
      @roles = RelayRole.includes(:peers).order(:name)
      @browsers = Relay::Settings.cloud_settings["browsers"]
    end

    # The templates, and what they become for every row that has the role
    # (and for the browsers, if it is theirs).
    def show
      config = Relay::Applier.config_for
      @rows = @role.peers.includes(:certificates, :roles).order(:name).map do |p|
        [ p, config.expansion_for(p.to_config.merge("roles" => [ @role.name ])) ]
      end
      settings = Relay::Settings.cloud_settings
      if @role.for_browsers?
        @browsers = config.expansion_for("name" => "browsers", "roles" => [ @role.name ],
                                         "nodes" => [ settings["browser_nodes"] ])
      end
      @browsers_listen = settings["browsers"]
    end

    def new
      @role = RelayRole.new
    end

    def create
      @role = RelayRole.new(role_params)
      if @role.save
        redirect_to relay_role_path(@role), notice: "Made the role #{@role.name}. Pick it on rows of the registry, then apply."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @role.update(role_params)
        redirect_to relay_role_path(@role), notice: "Saved. Apply to change the cloud router."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @role.destroy!
      redirect_to relay_roles_path, notice: "Removed the role #{@role.name}. Apply to change the cloud router.",
                                    status: :see_other
    end

    private

    def set_role
      @role = RelayRole.find(params[:id])
    end

    def role_params
      params.expect(relay_role: %i[ name description rw_templates read_templates ask_templates watch_templates
                                    for_browsers ])
    end
  end
end
