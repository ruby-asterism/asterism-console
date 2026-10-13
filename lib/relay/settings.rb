# Where the relay's generated configuration goes and how the cloud router
# is restarted (the environment). The defaults are the layout of
# deploy/vps: the console writes the file and asks for a restart by
# writing restart.request next to it (bin/relay_restart_request), which the
# router's container watches (deploy/vps/zenohd/run.sh). Any router that
# reads the file and restarts on the request works the same way; or set
# ASTERISM_RELAY_RESTART to a command that restarts yours.
#
#   ASTERISM_RELAY_CLOUD_NAME     zenohd-cloud (its metadata/name and certificate name)
#   ASTERISM_RELAY_GENERATED_DIR  storage/relay/generated (cloud.json5 is written there)
#   ASTERISM_RELAY_CERTS_DIR      storage/relay/certs (this server's own router and bridge
#                                 certificates: relay:issue_local, bin/asterism setup)
#   ASTERISM_RELAY_COMPOSE_DIR    the console's directory (where the restart command runs)
#   ASTERISM_RELAY_RESTART        bin/relay_restart_request (e.g. "docker compose restart zenohd")
#
# What goes into the cloud router's configuration (Relay::CloudConfig):
#
#   ASTERISM_RELAY_LISTEN         tls/[::]:7448 (comma separated for more)
#   ASTERISM_RELAY_BROWSERS       a ws/ endpoint (ws/[::]:7449) lets the browser build in,
#                                 behind the proxy that checks passes (W4); unset: none
#   ASTERISM_BROWSER_NODE_PREFIX  wasm- (the browsers' node IDs start with it: ${node} of the
#                                 roles for browsers is <prefix>$*, and the console names a
#                                 browser page it opens <prefix><handle>, Relay::BrowserNode)
#   ASTERISM_RELAY_MAX_SESSIONS   64    (transport/unicast/max_sessions)
#   ASTERISM_RELAY_ACCEPT_PENDING 16    (transport/unicast/accept_pending)
#   ASTERISM_RELAY_ACCEPT_TIMEOUT 5000  (ms, transport/unicast/accept_timeout)
#   ASTERISM_RELAY_MAX_MESSAGE    4194304 (bytes, transport/link/rx/max_message_size)
require "shellwords"

module Relay
  module Settings
    module_function

    def cloud_name(env = ENV)
      env["ASTERISM_RELAY_CLOUD_NAME"].presence || "zenohd-cloud"
    end

    def cloud_settings(env = ENV)
      int = ->(k) { env[k].presence && Integer(env[k]) }
      {
        "name" => cloud_name(env),
        "listen" => env["ASTERISM_RELAY_LISTEN"].presence&.split(",")&.map(&:strip),
        "browsers" => env["ASTERISM_RELAY_BROWSERS"].presence,
        "browser_nodes" => "#{browser_node_prefix(env)}$*",
        "max_sessions" => int.("ASTERISM_RELAY_MAX_SESSIONS"),
        "accept_pending" => int.("ASTERISM_RELAY_ACCEPT_PENDING"),
        "accept_timeout_ms" => int.("ASTERISM_RELAY_ACCEPT_TIMEOUT"),
        "max_message_size" => int.("ASTERISM_RELAY_MAX_MESSAGE")
      }.compact
    end

    def browser_node_prefix(env = ENV)
      prefix = env["ASTERISM_BROWSER_NODE_PREFIX"].presence || "wasm-"
      raise ArgumentError, "ASTERISM_BROWSER_NODE_PREFIX: #{prefix.inspect}" unless prefix.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,20}\z/)
      prefix
    end

    def generated_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_GENERATED_DIR"].presence || "storage/relay/generated", root)
    end

    def certs_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_CERTS_DIR"].presence || "storage/relay/certs", root)
    end

    def config_path(env = ENV, root: Rails.root)
      File.join(generated_dir(env, root: root), "cloud.json5")
    end

    def compose_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_COMPOSE_DIR"].presence || ".", root)
    end

    def restart_command(env = ENV, root: Rails.root)
      cmd = env["ASTERISM_RELAY_RESTART"].presence or return [ File.join(root.to_s, "bin/relay_restart_request") ]
      Shellwords.split(cmd)
    end
  end
end
