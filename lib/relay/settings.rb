# Where the relay's generated configuration goes and how the cloud router
# is restarted (the environment; the defaults fit the family-mruby
# repository with this one inside it, docker-compose.relay.yml).
#
#   ASTERISM_RELAY_CLOUD_NAME     zenohd-cloud (its metadata/name and certificate name)
#   ASTERISM_RELAY_GENERATED_DIR  storage/relay/generated (cloud.json5 is written there;
#                                 docker-compose.relay.yml mounts it with ASTERISM_RELAY_GENERATED)
#   ASTERISM_RELAY_COMPOSE_DIR    .. (the directory docker compose runs in)
#   ASTERISM_RELAY_RESTART        docker compose -f docker-compose.yml -f docker-compose.relay.yml restart zenohd-cloud
#
# What goes into the cloud router's configuration (Relay::CloudConfig):
#
#   ASTERISM_RELAY_LISTEN         tls/[::]:7448 (comma separated for more)
#   ASTERISM_RELAY_BROWSERS       a ws/ endpoint (ws/[::]:7449) lets the browser build in,
#                                 behind the proxy that checks passes (W4); unset: none
#   ASTERISM_RELAY_GAME           game (the app whose keys players use, G0)
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
        "game" => env["ASTERISM_RELAY_GAME"].presence,
        "max_sessions" => int.("ASTERISM_RELAY_MAX_SESSIONS"),
        "accept_pending" => int.("ASTERISM_RELAY_ACCEPT_PENDING"),
        "accept_timeout_ms" => int.("ASTERISM_RELAY_ACCEPT_TIMEOUT"),
        "max_message_size" => int.("ASTERISM_RELAY_MAX_MESSAGE")
      }.compact
    end

    def generated_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_GENERATED_DIR"].presence || "storage/relay/generated", root)
    end

    def config_path(env = ENV, root: Rails.root)
      File.join(generated_dir(env, root: root), "cloud.json5")
    end

    def compose_dir(env = ENV, root: Rails.root)
      File.expand_path(env["ASTERISM_RELAY_COMPOSE_DIR"].presence || "..", root)
    end

    def restart_command(env = ENV)
      cmd = env["ASTERISM_RELAY_RESTART"].presence ||
            "docker compose -f docker-compose.yml -f docker-compose.relay.yml restart #{cloud_name(env)}"
      Shellwords.split(cmd)
    end
  end
end
