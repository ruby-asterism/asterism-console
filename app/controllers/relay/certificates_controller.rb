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
                     "zenoh_config" => issuer.zenoh_config(@peer), "command" => issuer.command(@peer),
                     "info" => issuer.credentials_info(@peer, record, console: request.base_url),
                     "next" => fragment("issued_next"), "replace" => replacements },
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

    # The parts of the peer's page that issuing changes, rendered again for
    # the page to put in place (by element id): the relay tabs with the
    # "not yet applied" banner, the ACL badge, the next step, the ledger.
    def replacements
      @peer.reload
      { "relay-tabs" => render_to_string(partial: "relay/peers/tabs", formats: [ :html ]),
        "peer-acl" => helpers.tag.span(helpers.acl_badge(@peer), id: "peer-acl"),
        "peer-cert-status" => fragment("cert_status"),
        "peer-certs" => fragment("certificates") }
    end

    def fragment(name)
      render_to_string(partial: "relay/peers/#{name}", formats: [ :html ], locals: { peer: @peer })
    end

    def set_peer
      @peer = RelayPeer.find(params[:peer_id])
    end
  end
end
