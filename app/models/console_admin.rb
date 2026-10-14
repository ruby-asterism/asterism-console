# Where the console's admin pages may be used from, and whether an admin
# needs a second factor (W4). Both come from the environment:
#
#   CONSOLE_ADMIN_NETS  addresses / networks (comma separated, CIDR) the
#                       admin pages answer from; unset: from anywhere (the
#                       proxy in front still limits /admin by address)
#   CONSOLE_ADMIN_TOTP  "required" (the default in production) or "optional"
require "ipaddr"

module ConsoleAdmin
  module_function

  def networks(env = ENV)
    env["CONSOLE_ADMIN_NETS"].to_s.split(",").map(&:strip).reject(&:empty?).map { IPAddr.new(_1) }
  end

  def network_allowed?(ip, env = ENV)
    nets = networks(env)
    return true if nets.empty?
    addr = IPAddr.new(ip.to_s)
    addr = addr.native if addr.ipv4_mapped?
    nets.any? { _1.include?(addr) }
  rescue IPAddr::InvalidAddressError
    false
  end

  # Whether the graph shows the rooms (0.2.1, docs/rooms.md) to this user
  # from this address: to an admin who could use the admin pages from there.
  def rooms_visible?(user, ip, env = ENV)
    return false unless user&.admin? && network_allowed?(ip, env)
    !(totp_required?(env) && !user.otp_enabled?)
  end

  def totp_required?(env = ENV)
    v = env["CONSOLE_ADMIN_TOTP"].presence || (Rails.env.production? ? "required" : "optional")
    v == "required"
  end
end
