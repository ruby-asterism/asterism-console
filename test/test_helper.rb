ENV["RAILS_ENV"] ||= "test"
ENV["ASTERISM_RECORDINGS_DIR"] ||= File.expand_path("../tmp/test-recordings", __dir__)
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Recordings (V4) go to a directory of their own per test process.
    parallelize_setup do |worker|
      ENV["ASTERISM_RECORDINGS_DIR"] = Rails.root.join("tmp/test-recordings-#{worker}").to_s
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
