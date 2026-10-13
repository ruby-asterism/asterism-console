# The console's version (VERSION at the repository's root; the published
# image ghcr.io/ruby-asterism/asterism-console carries the same number as
# its tag), and how people get an account here.
#
#   ASTERISM_ENROLLMENT  admin (the default, and the only one for now): an
#                        admin registers every router and node and invites
#                        every user. Planned (docs/o1.md, not available):
#                        "approval" (people ask, an admin approves) and
#                        "self" (people add their own nodes within limits).
module AsterismConsole
  VERSION = File.read(File.expand_path("../../VERSION", __dir__)).strip.freeze

  ENROLLMENTS = %w[admin].freeze
  PLANNED_ENROLLMENTS = %w[approval self].freeze

  def self.enrollment(env = ENV)
    mode = env["ASTERISM_ENROLLMENT"].presence || "admin"
    return mode if ENROLLMENTS.include?(mode)
    if PLANNED_ENROLLMENTS.include?(mode)
      raise ArgumentError, "ASTERISM_ENROLLMENT=#{mode} is planned but not available in #{VERSION}; use admin"
    end
    raise ArgumentError, "ASTERISM_ENROLLMENT=#{mode}: one of #{ENROLLMENTS.join(', ')}"
  end
end

AsterismConsole.enrollment
