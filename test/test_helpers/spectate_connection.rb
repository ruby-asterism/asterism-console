# What a game host's second Asterism connection, the application
# "spectate" (asterism-games after Asterism wire protocol 2: an application
# of its own beside "game"), does on the router as the host's certificate:
# [message, flow, key] with the host's node "games" and a table's state.
# Its token and its calls' queryable, the liveliness watch and the
# duplicate check, the node's profile (each connection of the node answers
# it), the application's profile, status and topics, the table's values.
module SpectateConnection
  HOST = "games".freeze
  ACTIONS = [
    [ "liveliness_token", "ingress", "asterism/games/spectate" ],
    [ "declare_queryable", "ingress", "asterism/games/spectate/**" ],
    [ "declare_liveliness_subscriber", "ingress", "asterism/**" ],
    [ "liveliness_query", "ingress", "asterism/games/spectate/**" ],
    [ "declare_queryable", "ingress", "asterism/games/@profile" ],
    [ "put", "ingress", "asterism/games/@profile" ],
    [ "reply", "ingress", "asterism/games/@profile" ],
    [ "declare_queryable", "ingress", "asterism/games/spectate/@profile" ],
    [ "query", "egress", "asterism/games/spectate/@profile" ],
    [ "reply", "ingress", "asterism/games/spectate/@profile" ],
    [ "put", "ingress", "asterism/games/spectate/@status" ],
    [ "put", "ingress", "asterism/games/spectate/@pubs" ],
    [ "put", "ingress", "asterism/games/spectate/mahjong1/state" ],
    [ "put", "ingress", "asterism/games/spectate/room01-mahjong1/state" ]
  ].freeze

  # The actions the ACL refuses to the host (empty: it does all of them).
  def self.refused(acl, subject = HOST)
    ACTIONS.reject { |m, f, k| AclEvaluator.allowed?(acl, subject, m, f, k) }
  end
end
