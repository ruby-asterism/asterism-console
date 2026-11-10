# The node ID of a browser page a user opens from the console (G1.5,
# G1.5b): <prefix><handle>, the prefix of the browsers' node IDs
# (ASTERISM_BROWSER_NODE_PREFIX, wasm-) and the handle the user chose on
# the account page (User#handle), so the graph says whose browser it is
# without showing any part of the email address. A user without a handle
# has no browser node: the console asks for one first.
#
# Every page gets the user's own name (T8c; before, a second page at the
# same time got <base>_2 ... <base>_9 and came through the shared
# connection). The router checks that name (T8): the door connects the page
# that has it with the user's certificate (Relay::BrowserCerts,
# Relay::BrowserDoor) once an apply has let that in, and a page opened later
# takes it over from an earlier one, which goes on through the shared ws/
# connection (and says so). Pages before the apply come through ws/ too,
# where the name is what the console hands the page. Older links that still
# carry a <base>_2 name are not the user's own name: the door names none for
# them (BrowserPassesController#browser_header).
module Relay
  module BrowserNode
    module_function

    # The user's own base name, or nil without a handle.
    def base(user, prefix: Settings.browser_node_prefix)
      user.handle.present? ? "#{prefix}#{user.handle}" : nil
    end

    # The name for a new page: always the user's own (T8c).
    def pick(user, **opts)
      base(user, **opts) or raise ArgumentError, "#{user.log_name} has no handle"
    end
  end
end
