# Starts the applies that wait (G1.5b, RelayApply modes "idle" and "at"):
# every EVERY seconds it looks at the waiting one and runs it when its time
# has come (run_at reached) or nobody is connected (Relay::Applier#idle?).
# One thread in the console's server process (started by
# config/initializers/relay_apply_waiter.rb, and by the apply page when it
# makes a waiting apply); a console that restarts picks the waiting apply
# up again, since the state is in the database.
module Relay
  class ApplyWaiter
    EVERY = 5

    class << self
      # One look: the apply it started, or nil.
      def tick(at = Time.current, applier: -> { Applier.new })
        apply = RelayApply.waiting_one or return nil
        return nil if RelayApply.running_now?
        a = applier.call
        due = apply.mode == "at" ? apply.run_at <= at : a.idle?
        return nil unless due && apply.start!(at)
        Rails.logger.info("apply: #{apply.id} starts (#{apply.when_text})")
        a.run(apply, by: apply.user&.email_address)
      end

      def start!
        @mutex ||= Mutex.new
        @mutex.synchronize do
          return @thread if @thread&.alive?
          @thread = Thread.new do
            loop do
              Rails.application.executor.wrap { tick }
            rescue StandardError => e
              Rails.logger.warn("apply waiter: #{e.class}: #{e.message}")
            ensure
              sleep EVERY
            end
          end
        end
      end
    end
  end
end
