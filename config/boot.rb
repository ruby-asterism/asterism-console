ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# bin/rails server listens on 127.0.0.1 (in every environment) unless
# CONSOLE_BIND or -b says otherwise (config/initializers/exposure.rb).
ENV["BINDING"] ||= ENV.fetch("CONSOLE_BIND", "127.0.0.1")
