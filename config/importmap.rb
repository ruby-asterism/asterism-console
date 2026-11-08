# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/lib", under: "lib"
pin "cytoscape" # @3.34.3
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "cytoscape-fcose" # @2.2.0
pin "cose-base" # @2.2.0
pin "layout-base" # @2.0.1
pin "uplot" # @1.6.32
# The Terminal (docs/terminal.md) imports these when it opens; the other pages never load them.
pin "@xterm/xterm", to: "@xterm--xterm.js", preload: false # @6.0.0
pin "@xterm/addon-fit", to: "@xterm--addon-fit.js", preload: false # @0.11.0
