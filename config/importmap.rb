# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "cytoscape" # @3.34.3
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "cytoscape-fcose" # @2.2.0
pin "cose-base" # @2.2.0
pin "layout-base" # @2.0.1
pin "uplot" # @1.6.32
