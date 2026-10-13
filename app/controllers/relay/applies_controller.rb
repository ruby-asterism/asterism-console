module Relay
  # Applying the registry: the plan (who joins or leaves, what the restart
  # cuts) and the configuration first, then write it and restart the cloud
  # router. The restart runs on a thread; the page follows it.
  #
  # When (G1.5b): now, when nobody is connected, or at a time. The last two
  # wait (Relay::ApplyWaiter starts them) and can be cancelled; one waits at
  # a time, and a new apply replaces it.
  class AppliesController < ApplicationController
    require_admin
    layout "plain"

    def index
      @applies = RelayApply.includes(:user, :cancelled_by).order(id: :desc).limit(50)
    end

    def new
      @applier = Relay::Applier.new
      @plan = @applier.plan
      @config = Relay::Applier.config_for
      @running = RelayApply.running_now?
      @waiting = RelayApply.waiting_one
    end

    def create
      mode = params[:mode].presence || "now"
      return head :unprocessable_content unless RelayApply::MODES.include?(mode)
      if mode == "now" && RelayApply.running_now?
        return redirect_to new_relay_apply_path, alert: "An apply is still running."
      end
      run_at = nil
      if mode == "at"
        run_at = parse_time(params[:run_at], params[:tz_offset])
        return redirect_to new_relay_apply_path, alert: "Give the time to apply at." unless run_at
        return redirect_to new_relay_apply_path, alert: "That time has passed." if run_at < 1.minute.ago
      end
      RelayApply.waiting.find_each { _1.cancel!(current_user) }
      apply = RelayApply.create!(user: current_user, status: mode == "now" ? "running" : "waiting", mode: mode,
                                 run_at: run_at, started_at: (Time.current if mode == "now"))
      if mode == "now"
        self.class.runner.call(apply.id, current_user.email_address)
      else
        Rails.logger.info("apply: #{apply.id} waits (#{apply.when_text})")
        self.class.waiter.call
      end
      redirect_to relay_apply_path(apply)
    end

    def show
      @apply = RelayApply.find(params[:id])
    end

    def cancel
      apply = RelayApply.find(params[:id])
      if apply.cancel!(current_user)
        Rails.logger.info("apply: #{apply.id} cancelled")
        redirect_back fallback_location: relay_apply_path(apply), notice: "The waiting apply #{apply.id} is cancelled."
      else
        redirect_back fallback_location: relay_apply_path(apply), alert: "Apply #{apply.id} is not waiting (#{apply.status})."
      end
    end

    # A datetime-local value ("2026-10-13T21:30") with the browser's offset
    # from UTC in minutes (Date#getTimezoneOffset: UTC - local), or UTC when
    # the page did not say.
    private def parse_time(text, offset)
      t = Time.strptime(text.to_s, "%Y-%m-%dT%H:%M") rescue nil
      return nil unless t
      off = Integer(offset.presence || "0", exception: false) || 0
      Time.utc(t.year, t.month, t.day, t.hour, t.min) + off.minutes
    end

    # How create runs the apply (a thread; the tests replace it).
    class_attribute :runner, default: lambda { |id, by|
      Thread.new do
        Rails.application.executor.wrap do
          Relay::Applier.new.run(RelayApply.find(id), by: by)
        end
      end
    }

    # How create makes sure the waiter runs (the tests replace it).
    class_attribute :waiter, default: -> { Relay::ApplyWaiter.start! }
  end
end
