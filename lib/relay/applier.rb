# Applies the registry to the cloud router: writes the configuration made
# from it (Relay::CloudConfig) and restarts the router (docker compose
# restart, Relay::Settings.restart_command). Before: the plan (who joins or
# leaves the ACL, and every session and router link on the cloud router,
# all of which the restart cuts). After: what the bridge sees back on the
# cloud router within WAIT_BACK seconds.
require "open3"
require "timeout"
require "fileutils"

module Relay
  class Applier
    WAIT_BACK = 20
    RESTART_TIMEOUT = 60

    # What happens to the others when the cloud router restarts (W1, W2).
    NOTES = [
      "Every link to the cloud router is cut for a few seconds.",
      "A router that connects to it (the home router) connects again by itself.",
      "The console's bridge connects again by itself (every 3 s).",
      "Asterism nodes connected to it (CRuby, boards) do not connect again: restart them.",
      "ROS 2 peers connect again and their topics flow, but their liveliness tokens " \
      "(the ROS 2 nodes in the graph) may not come back until they restart."
    ].freeze

    def self.config_for(peers = RelayPeer.includes(:certificates).to_a)
      CloudConfig.new(peers.map(&:to_config), "name" => Settings.cloud_name)
    end

    def initialize(config: self.class.config_for, path: Settings.config_path, command: Settings.restart_command,
                   chdir: Settings.compose_dir, graph: -> { GraphState.uncached { GraphState.current } },
                   wait_back: WAIT_BACK)
      @config = config
      @path = path
      @command = command
      @chdir = chdir
      @graph = graph
      @wait_back = wait_back
    end

    def current_text
      File.exist?(@path) ? File.read(@path) : nil
    end

    # What would change and what the restart cuts (from the graph now).
    def plan
      old = CloudConfig.subjects_of(current_text)
      new = @config.subject_names
      on_cloud = cloud_view(@graph.call.graph)
      {
        "config_path" => @path, "written_before" => !old.nil?,
        "same_config" => current_text.to_s.include?("digest #{@config.digest}."),
        "subjects" => new, "joining" => old ? new - old : new, "leaving" => old ? old - new : [],
        "cloud_seen" => on_cloud[:seen], "cut" => on_cloud[:sessions], "router_links" => on_cloud[:routers],
        "command" => @command.join(" "), "notes" => NOTES
      }
    end

    # Writes the file and restarts; fills apply (a RelayApply) as it goes.
    def run(apply, by: nil)
      plan = self.plan
      text = @config.text(by: by)
      apply.update!(config_text: text, config_digest: @config.digest, plan_json: JSON.generate(plan))
      write(text)
      state = @graph.call
      before_id = cloud_view(state.graph)[:id]
      out, ok = restart
      apply.update!(output: out)
      after = ok ? wait_back(state.version, before_id) : {}
      apply.update!(status: ok ? "ok" : "failed", after_json: JSON.generate(after), finished_at: Time.current)
      apply
    rescue StandardError => e
      apply.update!(status: "failed", output: [ apply.output, "#{e.class}: #{e.message}" ].compact.join("\n"),
                    finished_at: Time.current)
      apply
    end

    def write(text)
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp#{Process.pid}"
      File.write(tmp, text)
      File.chmod(0o644, tmp)
      File.rename(tmp, @path)
    end

    def restart
      out = +""
      status = nil
      Timeout.timeout(RESTART_TIMEOUT) do
        out, status = Open3.capture2e(*@command, chdir: @chdir)
      end
      [ "$ #{@command.join(' ')}\n#{out}", status.success? ]
    rescue Timeout::Error
      [ "$ #{@command.join(' ')}\n(no end within #{RESTART_TIMEOUT} s)", false ]
    rescue SystemCallError => e
      [ "$ #{@command.join(' ')}\n#{e.class}: #{e.message}", false ]
    end

    # Waits for the bridge to show the cloud router again (a newer graph),
    # then a little longer for the others to come back. (The graph is read
    # past the query cache: the apply runs inside the executor, whose cache
    # would keep handing back the graph from before the restart.)
    # A restarted zenohd has a new ID (unless its configuration fixes one),
    # which tells the graph after the restart from a stale one.
    def wait_back(version, before_id = nil)
      deadline = mono + @wait_back
      seen_at = nil
      while mono < deadline
        state = @graph.call
        view = cloud_view(state.graph)
        fresh = before_id.nil? || view[:id] != before_id || mono > deadline - (@wait_back / 2.0)
        if state.version > version && view[:seen] && fresh
          seen_at ||= mono
          break if mono - seen_at > 6
        end
        sleep 1
      end
      view = cloud_view(@graph.call.graph)
      { "cloud_seen" => view[:seen], "sessions" => view[:sessions], "router_links" => view[:routers],
        "waited_s" => @wait_back }
    end

    # The cloud router's sessions and router links in a graph (to_h form),
    # each with what it carries (Asterism / ROS 2 nodes).
    def cloud_view(graph)
      nodes = graph["nodes"].to_a.to_h { [ _1["id"], _1 ] }
      cloud = nodes.values.find { _1["kind"] == "router" && _1.dig("data", "name") == @config.settings["name"] }
      return { seen: false, sessions: [], routers: [] } unless cloud
      edges = graph["edges"].to_a
      carried = Hash.new { |h, k| h[k] = [] }
      edges.select { _1["kind"] == "carries" }.each { carried[_1["source"]] << nodes.dig(_1["target"], "label") }
      sessions = edges.select { _1["kind"] == "session" && _1["source"] == cloud["id"] }.filter_map do |e|
        s = nodes[e["target"]] or next
        { "id" => s["id"], "label" => s["label"], "protocol" => s.dig("data", "protocol"),
          "self" => s.dig("data", "self") ? true : false, "carries" => carried[s["id"]].compact.sort }
      end
      routers = edges.select { _1["kind"] == "router_link" && [ _1["source"], _1["target"] ].include?(cloud["id"]) }
                     .map { |e| nodes.dig([ e["source"], e["target"] ].find { _1 != cloud["id"] }, "label") }
      { seen: true, id: cloud["id"], sessions: sessions.sort_by { _1["label"].to_s }, routers: routers.compact.sort }
    end

    private

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
