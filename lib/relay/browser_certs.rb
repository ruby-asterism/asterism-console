# The browsers' certificates (T8, docs/g1_5.md "Browsers the router tells
# apart"): one per user with a handle, named after the user's browser node,
# <prefix><handle> (wasm-alice, Relay::BrowserNode.base). The key is made
# on this server and the signer signs it, as for the rooms' seats
# (Relay::RoomCerts); the browser never has it. The door (bin/ws_door,
# Relay::BrowserDoor) connects a page that came with a pass of that user,
# for that node, to zenohd's mutual-TLS port with it, so the router sees the
# page as its own subject: wasm-alice writes and calls as wasm-alice only
# (Relay::CloudConfig). Pages without (before an apply, a second page of
# the same user, an older link) go on through zenohd's ws/ as before.
#
# The store is in the rooms' directory, which the door reads already
# (Relay::Settings.rooms_dir, browsers/):
#
#   browsers/wasm-alice.key (0600), browsers/wasm-alice.pem, browsers/ca.pem
#   browsers/browsers.json   the names the router's configuration lets in now
#                            (written on apply): {"format": 1, "written_at", "nodes": [...]}
#
# A certificate is made when the user chooses a handle (and for the users
# who have one by bin/asterism setup, which the update runs, or the
# Browsers page), 365 days, renewed within 30 days of its end like the
# seats'. A handle given up takes its files with it: the old name is not
# used again, and is out of the ACL at the next apply. No ledger entry is
# kept: the files are the record.
require "fileutils"
require "json"
require "openssl"
require "securerandom"

module Relay
  module BrowserCerts
    DAYS = 365
    DOOR_FILE = "browsers.json".freeze
    # The key the console signs its word to the door with (X-Asterism-Browser):
    # the door takes a page's node only with the console's signature, never
    # from a header a browser could have sent itself through the web server.
    DOOR_KEY = "door.key".freeze

    module_function

    def dir(env = ENV)
      File.join(Settings.rooms_dir(env), "browsers")
    end

    def door_file(env = ENV) = File.join(dir(env), DOOR_FILE)

    # The certificate's name (and node ID) of user's browser, or nil.
    def name_for(user, env = ENV)
      BrowserNode.base(user, prefix: Settings.browser_node_prefix(env))
    end

    # The names of the users' certificates that are good at at, sorted:
    # what the next configuration's ACL has.
    def names(env = ENV, at: Time.now)
      d = dir(env)
      User.where.not(handle: nil).order(:handle).filter_map { name_for(_1, env) }.select { good?(d, _1, at) }
    rescue ActiveRecord::ActiveRecordError
      []
    end

    # The console's key for its word to the door (made on first use, 0600).
    def door_key(env = ENV)
      path = File.join(dir(env), DOOR_KEY)
      key = File.read(path).strip if File.exist?(path)
      return key if key.to_s.match?(/\A\h{64}\z/)
      FileUtils.mkdir_p(dir(env))
      tmp = "#{path}.tmp#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { _1.write(SecureRandom.hex(32) + "\n") }
      File.rename(tmp, path)
      File.read(path).strip
    end

    # The console's word to the door for a page (T8): "node=...; pass=...;
    # notice=0|1; until=...; mac=..." (HMAC-SHA256 of the part before mac
    # with door_key). Relay::BrowserDoor.verify reads it.
    def door_word(node:, pass:, notice:, until_at:, env: ENV)
      text = "node=#{node}; pass=#{pass}; notice=#{notice ? 1 : 0}; until=#{until_at.to_i}"
      "#{text}; mac=#{OpenSSL::HMAC.hexdigest('SHA256', door_key(env), text)}"
    end

    # What the router's configuration takes (Relay::CloudConfig's
    # "browser_certs"): each user with a good certificate, its name and its
    # lists of whom its browser receives files from.
    def config_entries(env = ENV, at: Time.now)
      d = dir(env)
      User.where.not(handle: nil).order(:handle).filter_map do |u|
        name = name_for(u, env)
        next unless name && good?(d, name, at)
        { "name" => name, "receives" => u.receives_config, "receivers_managed" => u.managed_receivers? }
      end
    rescue ActiveRecord::ActiveRecordError
      []
    end

    def good?(d, name, at = Time.now) = RoomCerts.good?(d, name, at)

    # [common name, not_before, not_after] of a user's certificate, or nil.
    def info(name, env = ENV) = RoomCerts.info(dir(env), name)

    # Whether the router's configuration now (the file the cloud router
    # runs with) lets name in.
    def applied?(name, config_text = current_config)
      Array(CloudConfig.subjects_of(config_text)).include?(name)
    end

    def current_config(path = Settings.config_path)
      File.exist?(path) ? File.read(path) : nil
    end

    def ca_pem(issuer_signer = nil)
      (issuer_signer || Issuer.signer || SignerClient.from_env(root: Rails.root.to_s)).ca_pem
    end

    # Makes or renews user's certificate. Returns "in place" or "issued ...".
    # Raises Issuer::Error / SignerClient::Error when the signer cannot.
    def ensure_for!(user, ca_pem: self.ca_pem, issuer: Issuer.new, env: ENV)
      name = name_for(user, env) or return "no handle"
      out = dir(env)
      FileUtils.mkdir_p(out)
      CertAuthority.write(File.join(out, "ca.pem"), ca_pem, 0o644)
      RoomCerts.ensure_one(name, out, ca_pem, issuer)
    end

    # After user's handle changed (or was chosen): the old name's files go,
    # the new name's certificate is made. Returns nil, or why it was not
    # made (the signer did not answer: setup or the Browsers page makes it
    # later).
    def handle_changed(user, old_handle, env: ENV)
      if old_handle.present? && old_handle != user.handle
        forget!("#{Settings.browser_node_prefix(env)}#{old_handle}", env)
      end
      return nil if user.handle.blank?
      what = ensure_for!(user, env: env)
      Rails.logger.info("browsers: #{name_for(user, env)}: #{what}")
      nil
    rescue Issuer::Error, SignerClient::Error, SystemCallError => e
      Rails.logger.warn("browsers: #{name_for(user, env)}: not issued (#{e.message})")
      e.message
    end

    # Every user with a handle; the files of names no user has are removed.
    # Yields [name, what happened] for each.
    def ensure!(ca_pem, env: ENV, issuer: Issuer.new)
      User.where.not(handle: nil).order(:handle).each do |u|
        what = begin
          ensure_for!(u, ca_pem: ca_pem, issuer: issuer, env: env)
        rescue Issuer::Error, SignerClient::Error => e
          "not issued (#{e.message})"
        end
        yield name_for(u, env), what if block_given?
      end
      prune!(env)
    end

    # Removes the files of names that are no user's (a handle given up, a
    # user removed). Returns the names removed.
    def prune!(env = ENV)
      d = dir(env)
      return [] unless File.directory?(d)
      keep = User.where.not(handle: nil).filter_map { name_for(_1, env) }.to_set
      prefix = Settings.browser_node_prefix(env)
      gone = Dir.children(d).filter_map { _1[/\A(.+)\.(?:pem|key)\z/, 1] }.uniq
                .select { _1.start_with?(prefix) }.reject { keep.include?(_1) }
      gone.each { forget!(_1, env) }
      gone.sort
    end

    # A name's files away (its handle was given up), and out of the door's
    # list at once: the old name is not used again, also before the apply
    # that takes it out of the ACL.
    def forget!(name, env = ENV)
      return if name.blank?
      d = dir(env)
      %w[pem key].each { FileUtils.rm_f(File.join(d, "#{name}.#{_1}")) }
      write_door_file!(env: env) if File.exist?(door_file(env))
    end

    # The door's list: the names the router's configuration (the file the
    # cloud router runs with) lets in and whose files are here. Written on
    # every apply (Relay::Applier) and when a name goes.
    def write_door_file!(config_text = nil, env: ENV)
      config_text ||= current_config(Settings.config_path(env))
      d = dir(env)
      applied = Array(CloudConfig.subjects_of(config_text))
      prefix = Settings.browser_node_prefix(env)
      nodes = applied.select { _1.start_with?(prefix) && good?(d, _1) }.sort
      FileUtils.mkdir_p(d)
      path = door_file(env)
      tmp = "#{path}.tmp#{Process.pid}"
      File.write(tmp, JSON.pretty_generate({ "format" => 1, "written_at" => Time.now.utc.iso8601, "nodes" => nodes }) + "\n")
      File.chmod(0o644, tmp)
      File.rename(tmp, path)
      nodes
    end
  end
end
