# The node ID of a browser page a user opens from the console (G1.5):
# <prefix><user>, the prefix of the browsers' node IDs
# (ASTERISM_BROWSER_NODE_PREFIX, wasm-) and a name made from the user's
# email address, so the graph says whose browser it is.
#
# - The name: the part before the @, lower case, every run of characters
#   other than a-z and 0-9 made one "-", at most 20 characters; empty, it
#   is "user<id>". Two users whose names come out the same: the one
#   registered later gets ".<id>" added (stable: the earlier one keeps the
#   plain name).
# - A second page of the same user at the same time: the first of
#   <base>, <base>_2 ... <base>_9 that is neither on the graph now nor named
#   by a pass that is still waiting to be used or was used in the last
#   JUST_USED seconds (a page that is connecting is not on the graph yet);
#   all taken, <base>_<3 random hex>.
# A name never has "." or "_" in it, so the suffixes cannot make another
# user's name.
#
# The router does not check any of this (it cannot tell browsers apart,
# docs/g1_5.md): the name is what the console hands the page.
require "securerandom"

module Relay
  module BrowserNode
    JUST_USED = 30.seconds
    SLOTS = 9

    module_function

    def slug(user)
      s = user.email_address.to_s.split("@").first.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
      s = s.gsub(/\A-+|-+\z/, "")[0, 20].sub(/-+\z/, "")
      s.empty? ? "user#{user.id}" : s
    end

    # The user's own base name (without the slot).
    def base(user, prefix: Settings.browser_node_prefix, users: User.order(:id).to_a)
      mine = slug(user)
      first = users.find { slug(_1) == mine }
      "#{prefix}#{mine}#{".#{user.id}" if first && first.id != user.id}"
    end

    # The name for a new page: the base, or the next free slot.
    def pick(user, seen: Presence.seen(GraphState.current.graph), at: Time.current, **opts)
      b = base(user, **opts)
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
