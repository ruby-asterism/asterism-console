# What a game host's Asterism connections do on the router as the host's
# certificate (asterism-games after the shared places of Asterism wire
# protocol 2): [message, flow, key] with the host's node "games".
#
#   games    the permanent tables' application: it declares and puts the
#            tables' spectate views on its node's shared place
#   room01   a room's host, an application of the host's node outside the
#            room (room<slot>): its token and calls' queryable, the
#            duplicate check, the node's profile (each connection of the
#            node answers it), its own profile, status and topics, and the
#            room's tables' spectate views on the same shared place
#
# There is no "spectate" application any more (it was a second connection
# of the host before the shared places).
module GameHostConnections
  HOST = "games".freeze
  ACTIONS = [
    [ "put", "ingress", "asterism/games/@shared/spectate/mahjong1/state" ],
    [ "put", "ingress", "asterism/games/games/@pubs" ],
    [ "liveliness_token", "ingress", "asterism/games/room01" ],
    [ "declare_queryable", "ingress", "asterism/games/room01/**" ],
    [ "declare_liveliness_subscriber", "ingress", "asterism/**" ],
    [ "liveliness_query", "ingress", "asterism/games/room01/**" ],
    [ "declare_queryable", "ingress", "asterism/games/@profile" ],
    [ "put", "ingress", "asterism/games/@profile" ],
    [ "reply", "ingress", "asterism/games/@profile" ],
    [ "declare_queryable", "ingress", "asterism/games/room01/@profile" ],
    [ "query", "egress", "asterism/games/room01/@profile" ],
    [ "reply", "ingress", "asterism/games/room01/@profile" ],
    [ "put", "ingress", "asterism/games/room01/@status" ],
    [ "put", "ingress", "asterism/games/room01/@pubs" ],
    [ "put", "ingress", "asterism/games/@shared/spectate/room01-mahjong1/state" ]
  ].freeze

  # The actions the ACL refuses to the host (empty: it does all of them).
  def self.refused(acl, subject = HOST)
    ACTIONS.reject { |m, f, k| AclEvaluator.allowed?(acl, subject, m, f, k) }
  end
end
