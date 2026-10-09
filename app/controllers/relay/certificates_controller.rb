module Relay
  # Issuing (through the signer) and revoking certificates. Issuing answers
  # with the download itself: the key is in it and nowhere else.
  class CertificatesController < ApplicationController
    require_admin
    before_action :set_peer

    def create
      record, tar, file = Relay::Issuer.new.issue(@peer, by: current_user)
      Rails.logger.info("relay: issued #{@peer.name} serial #{record.serial} for #{current_user.email_address}")
      response.headers["Cache-Control"] = "no-store"
      send_data tar, filename: file, type: "application/x-tar", disposition: "attachment"
    rescue Relay::Issuer::Error => e
      redirect_to relay_peer_path(@peer), alert: "Not issued: #{e.message}"
    end

    def revoke
      cert = @peer.certificates.find(params[:id])
      cert.revoke!(current_user)
      redirect_to relay_peer_path(@peer), status: :see_other,
                  notice: "Revoked serial #{cert.serial}. Apply to take #{@peer.name} out of the ACL " \
                          "if it has no other valid certificate."
    end

    private

    def set_peer
      @peer = RelayPeer.find(params[:peer_id])
    end
  end
end
