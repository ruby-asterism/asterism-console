module Relay
  # Applying the registry: the plan (who joins or leaves, what the restart
  # cuts) and the configuration first, then write it and restart the cloud
  # router. The restart runs on a thread; the page follows it.
  class AppliesController < ApplicationController
    require_admin only: %i[ create ]
    layout "plain"

    def index
      @applies = RelayApply.includes(:user).order(id: :desc).limit(50)
    end

    def new
      @applier = Relay::Applier.new
      @plan = @applier.plan
      @config = Relay::Applier.config_for
      @running = RelayApply.where(status: "running").where(created_at: 5.minutes.ago..).exists?
    end

    def create
      if RelayApply.where(status: "running").where(created_at: 5.minutes.ago..).exists?
        return redirect_to new_relay_apply_path, alert: "An apply is still running."
      end
      apply = RelayApply.create!(user: current_user, status: "running")
      by = current_user.email_address
      self.class.runner.call(apply.id, by)
      redirect_to relay_apply_path(apply)
    end

    def show
      @apply = RelayApply.find(params[:id])
    end

    # How create runs the apply (a thread; the tests replace it).
    class_attribute :runner, default: lambda { |id, by|
      Thread.new do
        Rails.application.executor.wrap do
          Relay::Applier.new.run(RelayApply.find(id), by: by)
        end
      end
    }
  end
end
