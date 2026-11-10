module Relay
  # The users' browsers the router tells apart (T8, docs/g1_5.md, Members >
  # Browsers): each user with a handle has a certificate for its browser
  # node (wasm-<handle>, Relay::BrowserCerts), which the door uses for the
  # user's own page once an apply has put it in the router's ACL. An admin
  # sees which are in the ACL and which wait for the apply, makes the
  # missing ones, and chooses whom each browser receives files from (the
  # same lists as a member row's, ReceiverLists).
  class BrowsersController < ApplicationController
    require_admin
    before_action :set_user, only: %i[ edit update ]
    layout "plain"

    def index
      @users = User.where.not(handle: nil).order(:handle).to_a
      @config = Relay::BrowserCerts.current_config
      @seen = Relay::Presence.seen(GraphState.current.graph)
    end

    def edit
    end

    def update
      if @user.update(receivers_params)
        redirect_to relay_browsers_path, notice: "Saved #{Relay::BrowserNode.base(@user)}'s lists. Apply to change the cloud router."
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Makes the missing certificates (and renews those ending soon).
    def certify
      ca = Relay::BrowserCerts.ca_pem
      made = []
      Relay::BrowserCerts.ensure!(ca) { |name, what| made << "#{name}: #{what}" unless what == "in place" }
      Rails.logger.info("browsers: #{made.empty? ? 'every certificate in place' : made.join('; ')} (by #{current_user.log_name})")
      redirect_to relay_browsers_path, notice: made.empty? ? "Every certificate is in place." : "#{made.join('; ')}. Apply to let them in."
    rescue Relay::SignerClient::Error, Relay::Issuer::Error => e
      redirect_to relay_browsers_path, alert: "The signer: #{e.message}"
    end

    private

    def set_user
      @user = User.where.not(handle: nil).find(params[:id])
    end

    def receivers_params
      params.expect(user: [ :receive_files_from_more, :receive_checkpoints_from_more,
                            { receive_files_from_picked: [] }, { receive_checkpoints_from_picked: [] } ])
    end
  end
end
