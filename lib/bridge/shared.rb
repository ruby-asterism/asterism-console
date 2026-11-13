# The shared places of Asterism wire protocol 2 (docs/protocol.md 17 of the
# asterism gem): data with no single owner, apart from the applications'
# own places.
#
#   asterism/<node>/@shared/<name>   a node's place (its applications write
#                                    there: copies of what the node gives)
#   asterism/@shared/<name>          the whole network's place
#
# Such a place has no liveliness token, no objects and no profile: an
# application declares what it puts there in its own @pubs, under the
# entry "<node>/@shared/<name>" or "@shared/<name>" (the key under
# "asterism/"). Several applications may put on one key; each value's
# attachment names its sender ([seq, id, ms or nil, "<node>/<app>"]) and the
# numbers count per sender. The type is read from the sender's own
# declaration and definitions.
#
# The chunk @shared starts with @, so a ** never matches it: asterism/**
# does not reach the shared places, and a subscription that follows the
# applications' data needs the places' expressions beside it (companions).
#
# Plain Ruby (no asterism gem): the graph uses it in Puma too.
module Bridge
  module Shared
    CHUNK = "@shared".freeze
    # The two places' expressions under asterism/.
    NODE_PLACES = "asterism/*/@shared/**".freeze
    GLOBAL_PLACE = "asterism/@shared/**".freeze
    # A sender as an attachment names it.
    SENDER = %r{\A[^/@*$?#][^/*$?#]*/[^/@*$?#][^/*$?#]*\z}

    module_function

    # [:node, node, name], [:global, nil, name], or nil: what a @pubs entry
    # (or a key without "asterism/") names.
    def place(entry)
      parts = entry.to_s.split("/", -1)
      if parts[0] == CHUNK
        name = parts[1..].join("/")
        return [ :global, nil, name ] if name?(parts[1..])
      elsif parts.size >= 3 && parts[1] == CHUNK && chunk?(parts[0])
        return [ :node, parts[0], parts[2..].join("/") ] if name?(parts[2..])
      end
      nil
    end

    # The place of a full key (asterism/...), or nil.
    def key_place(key)
      k = key.to_s
      k.start_with?("asterism/") ? place(k.delete_prefix("asterism/")) : nil
    end

    def key?(key) = !key_place(key).nil?

    # A sender ("<node>/<app>") as an attachment gives it, or nil.
    def sender(value)
      value.is_a?(String) && SENDER.match?(value) ? value : nil
    end

    # The expressions to subscribe beside expr so that the shared places
    # its ** would cover if @shared were an ordinary chunk are followed too:
    #   asterism/**          -> asterism/*/@shared/** and asterism/@shared/**
    #   asterism/<node>/**   -> asterism/<node>/@shared/**
    # Anything else: none (an expression that names a place reaches it).
    def companions(expr)
      e = expr.to_s
      return [ NODE_PLACES, GLOBAL_PLACE ] if e == "asterism/**"
      m = %r{\Aasterism/([^/@]+)/\*\*\z}.match(e)
      m ? [ "asterism/#{m[1]}/@shared/**" ] : []
    end

    def chunk?(c) = !c.empty? && !c.start_with?("@") && !c.match?(/[*$?#]/)

    def name?(parts) = !parts.empty? && parts.all? { chunk?(_1) }
  end
end
