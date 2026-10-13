# The waiter for applies that wait (Relay::ApplyWaiter, G1.5b): only in the
# server process (not in a console, a rake task, the bridge or the tests).
Rails.application.config.after_initialize do
  Relay::ApplyWaiter.start! if defined?(Rails::Server) && !Rails.env.test?
end
