# A recorded network instead of the bridge, for looking at the page (and
# screenshotting it headless) without a router: development only,
# CONSOLE_FIXTURE=1 (test/fixtures/files/busy_network.json) or
# CONSOLE_FIXTURE=<path of such a file> (config/initializers/fixture.rb).
#
# The file holds the inputs of Bridge::Graph.build (admin, asterism, ros,
# self_node, self_zids, own_links, self_cert, registry), so the page shows
# them through the current graph code, and the topic rates as the bridge
# would measure them ("rates", with "recorded_at" in ms: their times are
# moved to now when loaded).
module Bridge
  module Fixture
    module_function

    def load(file)
      JSON.parse(File.read(file))
    end

    def graph(inputs)
      Graph.build(
        admin: inputs["admin"] || {}, asterism: inputs["asterism"] || [], ros: inputs["ros"] || [],
        self_node: inputs["self_node"], self_zids: inputs["self_zids"] || [],
        own_links: inputs["own_links"] || {}, self_cert: inputs["self_cert"], registry: inputs["registry"]
      ).to_h
    end

    def rates(inputs, now_ms = (Time.now.to_f * 1000).round)
      shift = now_ms - (inputs["recorded_at"] || now_ms)
      (inputs["rates"] || {}).transform_values { |r| r.merge("at" => r["at"] && r["at"] + shift) }
    end

    # A GraphState that is not saved: what the page shows in fixture mode.
    def state(file)
      inputs = load(file)
      state = GraphState.new(version: 1, snapshot: JSON.generate(graph(inputs)), bridge_seen_at: Time.current,
                             bridge_info: JSON.generate("router" => "fixture #{File.basename(file)}",
                                                        "node" => inputs["self_node"], "fixture" => true))
      state.rates = rates(inputs)
      state
    end
  end
end
