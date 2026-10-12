module Relay
  # Issuing (through the signer) and revoking certificates. The key pair is
  # made in the admin's browser (Web Crypto); create takes the public key
  # only (spki, base64 of the DER) and answers with the certificate and the
  # CA, which the page shows next to the private key it kept. Nothing here
  # ever sees a private key.
  class CertificatesController < ApplicationController
    require_admin
    before_action :set_peer

    def create
      response.headers["Cache-Control"] = "no-store"
      issuer = Relay::Issuer.new
      record, cert_pem, ca_pem = issuer.issue(@peer, params.require(:spki).to_s, by: current_user)
      Rails.logger.info("relay: issued #{@peer.name} serial #{record.serial} for #{current_user.email_address}")
      render json: { "name" => @peer.name, "serial" => record.serial,
                     "not_after" => record.not_after.utc.iso8601, "fingerprint" => record.fingerprint,
                     "certificate" => cert_pem, "ca" => ca_pem,
                     "zenoh_config" => issuer.zenoh_config(@peer), "command" => issuer.command(@peer) },
             status: :created
    rescue Relay::Issuer::Error => e
      render json: { "error" => e.message }, status: :unprocessable_content
    rescue ActionController::ParameterMissing
      render json: { "error" => "send the public key (spki)" }, status: :bad_request
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
