module Relay
  # The relay registry: the routers and clients the cloud router lets in.
  # Everyone signed in reads it; admins change it.
  class PeersController < ApplicationController
    require_admin except: %i[ index show ]
    before_action :set_peer, only: %i[ show edit update destroy ]
    layout "plain"

    def index
      @peers = RelayPeer.includes(:certificates).order(:kind, :name)
      @seen = Relay::Presence.seen(GraphState.current.graph)
      @cloud = Relay::Settings.cloud_name
      @plan = Relay::Applier.new.plan
    end

    def show
      @seen = Relay::Presence.seen(GraphState.current.graph)
    end

    def new
      @peer = RelayPeer.new(kind: params[:kind].presence_in(RelayPeer::KINDS) || "client",
                            name: params[:name], rw_keys: "asterism/**\n", cert_days: 90)
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
      params.expect(relay_peer: %i[ name kind description rw_keys ro_keys admin_space enabled
                                   dns_names ip_addresses cert_days ])
    end
  end
end
