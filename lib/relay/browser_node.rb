# The node ID of a browser page a user opens from the console (G1.5,
# G1.5b): <prefix><handle>, the prefix of the browsers' node IDs
# (ASTERISM_BROWSER_NODE_PREFIX, wasm-) and the handle the user chose on
# the account page (User#handle), so the graph says whose browser it is
# without showing any part of the email address. A user without a handle
# has no browser node: the console asks for one first.
#
# Handles are unique and never contain "_", so the slots below cannot make
# another user's name. A second page of the same user at the same time: the
# first of <base>, <base>_2 ... <base>_9 that is neither on the graph now
# nor named by a pass that is still waiting to be used or was used in the
# last JUST_USED seconds (a page that is connecting, or connecting again
# after the router restarted, is not on the graph); all taken,
# <base>_<3 random hex>.
#
# The router does not check any of this (it cannot tell browsers apart,
# docs/g1_5.md): the name is what the console hands the page.
require "securerandom"

module Relay
  module BrowserNode
    JUST_USED = 30.seconds
    SLOTS = 9

    module_function

    # The user's own base name (without the slot), or nil without a handle.
    def base(user, prefix: Settings.browser_node_prefix)
      user.handle.present? ? "#{prefix}#{user.handle}" : nil
    end

    # The name for a new page: the base, or the next free slot.
    def pick(user, seen: Presence.seen(GraphState.current.graph), at: Time.current, **opts)
      b = base(user, **opts) or raise ArgumentError, "#{user.log_name} has no handle"
      taken = seen.to_set | recent_names(at)
      ([ b ] + (2..SLOTS).map { "#{b}_#{_1}" }).find { !taken.include?(_1) } || "#{b}_#{SecureRandom.hex(2)[0, 3]}"
    end

    def recent_names(at)
      waiting = BrowserPass.live(at).where.not(node: nil).pluck(:node)
      just = BrowserPass.where.not(node: nil).where(last_used_at: (at - JUST_USED)..).pluck(:node)
      (waiting + just).to_set
    end
  end
end
