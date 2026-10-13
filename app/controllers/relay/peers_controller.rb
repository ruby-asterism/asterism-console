module Relay
  # The relay registry: the routers and clients the cloud router lets in.
  # Admins only (under /admin).
  class PeersController < ApplicationController
    require_admin
    before_action :set_peer, only: %i[ show edit update destroy ]
    layout "plain"

    def index
      @peers = RelayPeer.includes(:certificates, :roles).order(:kind, :name)
      @seen = Relay::Presence.seen(GraphState.current.graph)
      @cloud = Relay::Settings.cloud_name
      @plan = Relay::Applier.new.plan
    end

    def show
      response.headers["Cache-Control"] = "no-store" # the issuing page holds a key while open
      @seen = Relay::Presence.seen(GraphState.current.graph)
      @expansion = Relay::Applier.config_for.expansion_for(@peer.to_config)
    end

    # A router starts with its admin space read through (the graph shows what
    # is behind it); a client starts without reading the cloud router's, which
    # lists every session and its address. Nothing is allowed until roles or
    # keys are chosen (G1.5: no asterism/** by default).
    def new
      kind = params[:kind].presence_in(RelayPeer::KINDS) || "client"
      @peer = RelayPeer.new(kind: kind, name: params[:name], cert_days: 90, admin_space: kind == "router")
    end

    def create
      @peer = RelayPeer.new(peer_params)
      if @peer.save
        redirect_to relay_peer_path(@peer), notice: "Registered #{@peer.name}. Issue a certificate, then apply."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @peer.update(peer_params.except(:name))
        redirect_to relay_peer_path(@peer), notice: "Saved. Apply to change the cloud router."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @peer.destroy!
      redirect_to relay_peers_path, notice: "Removed #{@peer.name}. Apply to take it out of the ACL.", status: :see_other
    end

    private

    def set_peer
      @peer = RelayPeer.find(params[:id])
    end

    def peer_params
      params.expect(relay_peer: [ :name, :kind, :description, :rw_keys, :ro_keys, :admin_space, :enabled,
                                  :dns_names, :ip_addresses, :cert_days, :nodes, { role_ids: [] } ])
    end
  end
end
