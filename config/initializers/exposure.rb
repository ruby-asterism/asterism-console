# Listening beyond this machine (CONSOLE_BIND, config/puma.rb) is allowed
# only when somebody can sign in: the server refuses to start with no
# users, rather than serving a sign-in page nobody can pass. Sign-in itself
# is always required (Authentication); nothing here can turn it off.
require "ipaddr"

module ConsoleExposure
  def self.loopback?(host)
    return true if host.blank? || host == "localhost"
    IPAddr.new(host.delete_prefix("[").delete_suffix("]")).loopback?
  rescue IPAddr::InvalidAddressError
    false
  end

  # The address the server listens on: -b / --binding, else BINDING (which
  # config/boot.rb fills from CONSOLE_BIND, 127.0.0.1 by default).
  def self.listen_host(argv = ARGV, env = ENV)
    argv.each_with_index do |a, i|
      return argv[i + 1] if %w[-b --binding].include?(a)
      return a.split("=", 2)[1] if a.start_with?("--binding=")
      return a[2..] if a.start_with?("-b") && a.size > 2
    end
    env["BINDING"].presence || env["CONSOLE_BIND"]
  end

  def self.check!(host = listen_host)
    return :loopback if loopback?(host)
    raise "CONSOLE_BIND=#{host}: listening beyond this machine needs a user (bin/rails console:user)" unless User.exists?
    Rails.logger.warn("console: listening on #{host}; sign-in is required. Put TLS in front (README).")
    :exposed
  end
end

Rails.application.config.after_initialize do
  ConsoleExposure.check! if defined?(Rails::Server) || defined?(Puma::Server)
rescue ActiveRecord::ActiveRecordError
  nil # no database yet (db:prepare)
end
