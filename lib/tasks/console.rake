# Accounts. There is no sign-up page: an administrator makes users here.
# The password is read from the terminal (not echoed) or from
# CONSOLE_PASSWORD, never from the command line (it would stay in the
# shell history and show in ps).
#
#   bin/rails console:user EMAIL=me@example.org ADMIN=1
#   CONSOLE_PASSWORD=... bin/rails console:user EMAIL=me@example.org
#   bin/rails console:users
#   bin/rails console:otp_off EMAIL=me@example.org   # a user who lost the device
namespace :console do
  def read_password
    if (pw = ENV["CONSOLE_PASSWORD"].presence)
      return pw
    end
    require "io/console"
    abort "No terminal: set CONSOLE_PASSWORD instead." unless $stdin.tty?
    pw = $stdin.getpass("Password (12 characters or more): ")
    again = $stdin.getpass("Again: ")
    abort "The two did not match." unless pw == again
    pw
  end

  desc "Make a user, or set a new password (EMAIL=..., ADMIN=1 for an admin)"
  task user: :environment do
    email = ENV["EMAIL"].presence or abort "Set EMAIL=..."
    user = User.find_or_initialize_by(email_address: email.strip.downcase)
    fresh = user.new_record?
    user.password = read_password
    user.admin = ENV["ADMIN"] == "1" if ENV.key?("ADMIN") || fresh
    if user.save
      puts "#{fresh ? 'made' : 'updated'} #{user.email_address}#{' (admin)' if user.admin?}"
    else
      abort user.errors.full_messages.to_sentence
    end
  end

  desc "List the users"
  task users: :environment do
    User.order(:id).each do |u|
      puts [ u.email_address, u.admin? ? "admin" : "user", u.otp_enabled? ? "totp" : "-" ].join("\t")
    end
  end

  desc "Turn off a user's two-factor sign-in (EMAIL=...)"
  task otp_off: :environment do
    user = User.find_by!(email_address: ENV.fetch("EMAIL").strip.downcase)
    user.disable_otp!
    puts "two-factor sign-in off for #{user.email_address}"
  end
end
