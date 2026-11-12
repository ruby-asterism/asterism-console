require "test_helper"
require "open3"

# The member row form's "No expiry" (app/javascript/controllers/
# cert_lifetime_controller.js), run by Node from the same module the page
# loads, with Stimulus's Controller stood in by a plain class: ticking greys
# the certificate days and makes them read-only, unticking gives them back.
# Skipped without node.
class CertLifetimeControllerTest < ActiveSupport::TestCase
  MODULE = Rails.root.join("app/javascript/controllers/cert_lifetime_controller.js")

  SCRIPT = <<~JS.freeze
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
      .replace(/^import \\{ Controller \\} from "@hotwired\\/stimulus"$/m, "class Controller {}")
    import("data:text/javascript;base64," + Buffer.from(src).toString("base64")).then((m) => {
      const steps = JSON.parse(fs.readFileSync(0, "utf8"))
      const classes = new Set()
      const label = { classList: { toggle: (c, on) => on ? classes.add(c) : classes.delete(c) } }
      const days = { readOnly: false, tabIndex: 0, attrs: {}, setAttribute(k, v) { this.attrs[k] = v }, closest: () => label }
      const box = { checked: steps[0] }
      const c = new m.default()
      Object.assign(c, { hasDaysTarget: true, hasNoExpiryTarget: true, daysTarget: days, noExpiryTarget: box })
      const seen = []
      steps.forEach((checked, i) => {
        box.checked = checked
        i === 0 ? c.connect() : c.toggle()
        seen.push([days.readOnly, days.attrs["aria-disabled"], days.tabIndex, classes.has("unused")])
      })
      process.stdout.write(JSON.stringify(seen))
    })
  JS

  def run_steps(steps)
    out, err, st = Open3.capture3("node", "-e", SCRIPT, MODULE.to_s, stdin_data: JSON.generate(steps))
    assert st.success?, err
    JSON.parse(out)
  rescue SystemCallError
    skip "no node to run the browser module"
  end

  test "ticked on load greys the days; unticking gives them back, ticking again greys them" do
    assert_equal [ [ true, "true", -1, true ], [ false, "false", 0, false ], [ true, "true", -1, true ] ],
                 run_steps([ true, false, true ])
  end

  test "unticked on load leaves the days as they are" do
    assert_equal [ [ false, "false", 0, false ] ], run_steps([ false ])
  end
end
