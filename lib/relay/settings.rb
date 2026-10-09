# Where the relay's generated configuration goes and how the cloud router
# is restarted (the environment; the defaults fit the family-mruby
# repository with this one inside it, docker-compose.relay.yml).
#
#   ASTERISM_RELAY_CLOUD_NAME     zenohd-cloud (its metadata/name and certificate name)
#   ASTERISM_RELAY_GENERATED_DIR  storage/relay/generated (cloud.json5 is written there;
#                                 docker-compose.relay.yml mounts it with ASTERISM_RELAY_GENERATED)
#   ASTERISM_RELAY_COMPOSE_DIR    .. (the directory docker compose runs in)
#   ASTERISM_RELAY_RESTART        docker compose -f docker-compose.yml -f docker-compose.relay.yml restart zenohd-cloud
require "shellwords"

module Relay
  module Settings
    module_function

    def cloud_name(env = ENV)
      env["ASTERISM_RELAY_CLOUD_NAME"].presence || "zenohd-cloud"
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
