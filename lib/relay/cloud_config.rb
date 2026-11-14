# The cloud router's configuration (zenohd 1.10.1, JSON5) made from the
# relay registry: the TLS part and the access control (ACL). The registry
# (the console's database) is the source; the file says so in its first
# lines and is written again on every apply. Plain Ruby: the peers come in
# as hashes (RelayPeer#to_config), so the tests need no database.
#
# Per peer (subject = its certificate's common name):
#   rw keys  -> every message type, both directions
#   ro keys  -> what lets it receive: from it (ingress) only subscribing,
#               querying and liveliness queries; to it (egress) everything
#   admin    -> a client may read the admin space (@/**: query and reply);
#               a router's admin space may be read through this router
#   roles    -> (G1.5) each role's key templates (RelayRole), ${node}
#               expanded to every node the peer speaks for (its own name
#               unless the registry lists the boards behind a home router):
#                 rw     every message, both directions
#                 read   subscribing and liveliness queries from it,
#                        everything on those keys towards it
#                 ask    queries from it (an Asterism call or meta is a
#                        query): a role lets a node call only under its own
#                        name with asterism/*/<app>/*/call/${node}
#                 watch  the liveliness watch from it (asterism/**)
#               A template without ${node} is the same for every peer and
#               becomes one shared rule.
# Browsers (the wasm build, settings "browsers"): the ws/ listener is behind
# a proxy that checks a pass from the console (W4); the router itself cannot
# tell one browser from another, so every ws/ session gets the same rules:
# the roles marked for browsers, with ${node} expanded to the browsers' node
# pattern (settings "browser_nodes", wasm-$*). One browser can write at
# another browser's node; see docs/g0_w4.md and docs/g1_5.md.
#
# Rooms (G2, docs/rooms.md): a room slot (01 .. 08) is the key space
# room/<slot>/**, and, since a ** never matches a chunk that starts with
# @, room/<slot>/**/@adv/** for zenoh-ext's advanced publishers and
# subscribers (their history and recovery). Nothing else reaches it, and
# it reaches nothing else.
#
# Seats (0.3.0, docs/rooms.md "Seats"; settings "room_seats" => {"01" =>
# ["01", "02", ...]}, the seats whose certificates the rooms' store holds,
# Relay::RoomCerts; not registry rows since 0.3.1): the door gives each
# browser in a room a seat and connects with that seat's certificate
# (room-01-s03). A seat reads the whole room (subscriptions, liveliness,
# gets, room/<slot>/**, its @adv part and the nodes' @profile) and writes
# (put, delete, queryable, token, reply) only under its own node ID,
# <prefix><slot><seat> (wasm-0103). It calls under its own node ID only:
# zenohd 1.10.1 lets a deny win over an allow inside one subject but an
# allow of any subject win over the others, so the seat has two subjects
# for its one certificate, one (the common name alone) with "no calls" (a
# deny on .../call/**) and one (the common name and link_protocols tls)
# with "calls as itself" (an allow on .../call/<its node>). A registry row
# with a seat's name is left out: the name is the seat's.
#
# Game hosts in the rooms (0.3.0): a registry row named in "room_hosts"
# (games) gets, next to its roles, the rooms' tables: writes under
# room/*/asterism/<host>$* (the host in each room's namespace, and bots
# named <host>-...), the whole rooms to read and receive, and calls under
# its own names only (<host>$*) plus meta and profiles. Nobody else writes
# there: a seat writes only at its node.
#
# The console in the rooms (0.2.1): when there are seats, the console's
# own certificate (settings "console", the bridge's "console") may follow
# who is in the rooms and nothing more: from it only the liveliness watch
# and liveliness queries on room/*/asterism/**, to it only the tokens and
# the replies to those queries. No put, no subscription, no queryable, no
# query (an Asterism call is a query): it cannot write into a room or call
# an object in one. The rooms' own rules do not reach outside room/<slot>.
#
# The console's profiles (0.3.3): a ** never matches a chunk that starts
# with @, so the console's asterism/** does not reach asterism/<node>/@profile.
# The console's certificate gets a rule of its own for asterism/*/@profile:
# from it the query and the subscription, to it the replies and the puts
# (the graph's names, marks and icons, Bridge::Profiles). Nobody else gets
# it. The console both reads all the nodes' profiles and publishes its own
# (0.4.1: kind console, its name and icon): on its own node's key only,
# asterism/<console node>/@profile (settings "console_node"), from it the
# queryable, the replies and the put, to it the queries. It cannot answer
# or put another node's profile.
#
# The applications' own profiles (asterism protocol 2: an application
# answers asterism/<node>/<app>/@profile and puts its status and its
# topics' declarations on .../@status and .../@pubs, other verbatim chunks):
# the console's certificate gets the same kind of rules, from it the query
# of asterism/*/*/@profile and the subscriptions to asterism/*/*/@status and
# asterism/*/*/@pubs, to it the replies and the puts (the details of a node
# or an app and the recorder's schemas, Bridge::AppProfiles). A node whose
# applications tell a status or stream topics needs a role that lets it
# write asterism/${node}/*/@profile (its queryable and replies),
# asterism/${node}/*/@status and asterism/${node}/*/@pubs (docs/rooms.md:
# games-host).
#
# The shared places (asterism protocol 2: asterism/<node>/@shared/** and
# asterism/@shared/**, data with no owner; @shared is verbatim, so the
# console's asterism/** does not reach them): the console's certificate
# gets from it the subscription and the put (a recording's playback puts
# what it recorded there again), to it the puts. A node writes its own
# place with a role line asterism/${node}/@shared/** (docs/rooms.md:
# games-host); the network's place asterism/@shared/** is read by the
# example role "match" and written only where an admin's role says so.
#
# Files with the console (0.3.14, T4b, docs/files.md): a row marked
# files_to_console gets, for each node it speaks for, the ask line
# asterism/<console node>/transfer/inbox/call/<node> (the console's inbox,
# called under its own name only: the query from it, and the reply to it
# on the same keys; zenohd 1.10.1 checks a reply going to the caller
# against the caller's egress rules, and without it the calls go
# unanswered, which a role's ask line gets from its read lines); a row
# marked files_from_console gets the
# rw lines asterism/<node>/transfer and asterism/<node>/transfer/** (its
# inbox's tokens, queryable and replies, where the console sends). The
# rules are the row's own, beside its roles'; the settings "console_node"
# is the bridge's node ID (ASTERISM_CONSOLE_NODE).
#
# Who a machine receives files from (0.3.16, T6, docs/files.md): a row's
# lists (RelayPeer#receivers, "receives" => {"file" => [...], "checkpoint"
# => [...]}: node IDs and patterns with *) are matched against the nodes
# of the other rows in the ACL. A row with a node that matches gets, for
# each such node and each node of the receiving row, the ask line
# asterism/<receiver>/transfer/inbox/call/<sender> with the reply to it
# (the same rule pair as files_to_console; the two kinds share the inbox,
# so the ACL does not tell them apart: the machine does). The receiving
# row, once its lists were ever chosen ("receivers_managed"), gets the rw
# lines asterism/<node>/transfer and asterism/<node>/transfer/** (its
# inbox, and the console's call that brings the lists; kept when the lists
# are emptied, so that the empty list still reaches it).
#
# Browsers the router tells apart (T8, docs/g1_5.md; settings
# "browser_certs" => [{"name" => "wasm-alice", "receives" => {...},
# "receivers_managed" => bool}], Relay::BrowserCerts): a user's browser
# page that the door connects with the user's certificate (its common name
# is the page's node ID, wasm-<handle>) is a subject of its own, like a
# seat: the roles marked for browsers with ${node} its own name, no call
# under another name (a deny on asterism/*/*/*/call/** in the subject of
# the common name alone; the calls its roles allow, under its own name, in
# a second subject with link_protocols tls), and the transfer keys like a
# member's (its lists: the senders' ask lines, its inbox's rw; as a sender
# in others' lists, its ask lines in the second subject). A registry row
# with such a name is left out: the name is the browser's. The shared ws/
# subject (the pages without a certificate) is refused every transfer key
# (asterism/*/transfer and below): files only with a verified name.
#
# Subscribers' declarations towards publishers (asterism protocol 2): a
# topic's values go out through a declared publisher, which sends only
# while it knows a matching subscriber, and the router hands it the
# subscribers' declarations as egress declare_subscriber, checked against
# the publisher's own rules. A subscriber with a wildcard node
# (asterism/*/games/*/state, asterism/*/@shared/spectate/**) is not inside
# a node's own keys, so it never reached the publisher and got nothing
# unless a named subscriber was there too. Every registry row, browser
# certificate and the shared ws/ subject therefore gets one shared rule:
# egress declare_subscriber on asterism/** and the two shared places
# (SUBSCRIBERS). It tells a node the key expressions others subscribe to,
# nothing else: values, calls and writes keep their rules. The update's
# setup writes it with the rest (no migration). Seats and the rooms' hosts
# have it inside room/<slot>/** already.
#
# A peer that is disabled, or has no valid certificate in the ledger, is
# left out: its links are refused nothing by TLS (the certificate is still
# good until it expires; zenohd 1.10.1 has no revocation list), but the ACL
# denies it everything. Key names checked against zenoh 1.10.1's
# DEFAULT_CONFIG.json5.
require "json"
require "digest"
require "set"

module Relay
  class CloudConfig
    ALL = %w[put delete declare_subscriber query reply declare_queryable
             liveliness_token liveliness_query declare_liveliness_subscriber].freeze
    READ_IN = %w[declare_subscriber query liveliness_query declare_liveliness_subscriber].freeze
    # A role's sections (RelayRole) and the rules each becomes:
    # [suffix, messages, flows].
    SECTIONS = %w[rw read ask watch].freeze
    SECTION_RULES = {
      "rw" => [ [ "rw", ALL, %w[egress ingress] ] ],
      "read" => [ [ "read_in", %w[declare_subscriber liveliness_query], %w[ingress] ],
                  [ "read_out", ALL, %w[egress] ] ],
      "ask" => [ [ "ask", %w[query], %w[ingress] ] ],
      "watch" => [ [ "watch", %w[declare_liveliness_subscriber], %w[ingress] ] ]
    }.freeze
    VARIABLE = "${node}".freeze
    # What the console may do in the rooms (0.2.1): watch who is there.
    ROOMS_WATCH = "room/*/asterism/**".freeze
    ROOMS_IN = %w[declare_liveliness_subscriber liveliness_query].freeze
    ROOMS_OUT = %w[liveliness_token reply].freeze
    # The nodes' profiles the console reads (0.3.3): asterism/** does not
    # match the chunk @profile, so they need a rule of their own. From the
    # console its query and subscription, to it the replies and the puts.
    PROFILES = "asterism/*/@profile".freeze
    PROFILES_IN = %w[declare_subscriber query].freeze
    PROFILES_OUT = %w[put reply].freeze
    # The console's own profile (0.4.1), on its own node's key only: from
    # it the queryable, the replies and the put (as it connects), to it the
    # queries of the others.
    OWN_PROFILE_IN = %w[declare_queryable reply put].freeze
    OWN_PROFILE_OUT = %w[query].freeze
    # The applications' own profiles the console reads (protocol 2): the
    # same, for asterism/*/*/@profile (queries, ** does not match @profile
    # either) and the puts on asterism/*/*/@status and asterism/*/*/@pubs.
    APP_PROFILES = "asterism/*/*/@profile".freeze
    APP_PROFILES_IN = %w[query].freeze
    APP_PROFILES_OUT = %w[reply].freeze
    APP_NOTICES = [ "asterism/*/*/@status", "asterism/*/*/@pubs" ].freeze
    APP_NOTICES_IN = %w[declare_subscriber].freeze
    APP_NOTICES_OUT = %w[put].freeze
    # The shared places the console follows (protocol 2, Bridge::Shared).
    SHARED_PLACES = [ "asterism/*/@shared/**", "asterism/@shared/**" ].freeze
    SHARED_IN = %w[declare_subscriber put].freeze
    SHARED_OUT = %w[put].freeze
    # The subscribers' declarations every subject may be told of (see the
    # top of this file): the keys of the applications' topics and the
    # shared places (a ** never matches a chunk that starts with @).
    SUBSCRIBERS = [ "asterism/**", "asterism/*/@shared/**", "asterism/@shared/**" ].freeze
    SUBSCRIBERS_RULE = { "id" => "subscribers_out", "messages" => %w[declare_subscriber], "flows" => %w[egress],
                         "permission" => "allow", "key_exprs" => SUBSCRIBERS }.freeze
    # A seat's or a host's own writes in a room (0.3.0).
    OWN = %w[put delete declare_queryable liveliness_token reply].freeze
    ROOM_READ_IN = %w[declare_subscriber declare_liveliness_subscriber liveliness_query].freeze
    HEADER = "// GENERATED by asterism-console from its relay registry (the database is the\n" \
             "// source). Do not edit by hand: the next apply from the console writes it again.\n".freeze

    DEFAULTS = {
      "name" => "zenohd-cloud",
      "listen" => "tls/[::]:7448",
      "ca" => "/certs/ca.pem",
      "certificate" => "/certs/%<name>s.pem",
      "private_key" => "/certs/%<name>s.key",
      # ws/ endpoint for the browser build (behind the pass-checking proxy),
      # or nil: no browsers.
      "browsers" => nil,
      # What ${node} is for the browsers: their node IDs share a prefix.
      "browser_nodes" => "wasm-$*",
      # The console's own certificate (bin/asterism setup issues "console"):
      # the subject that may watch the rooms.
      "console" => "console",
      # Connection limits (zenoh 1.10.1, transport/unicast and link/rx).
      # 96 (G2): the rooms' connections come through the door on top of the
      # registered routers and nodes (docs/rooms.md).
      "max_sessions" => 96,
      "accept_pending" => 16,
      "accept_timeout_ms" => 5000,
      "max_message_size" => 4 * 1024 * 1024,
      # The rooms' seats (0.3.0): {slot => [seat, ...]} (Relay::RoomCerts.seats),
      # their node IDs <seat_node_prefix><slot><seat>.
      "room_seats" => {},
      "seat_node_prefix" => "wasm-",
      # Game hosts in the rooms (0.3.0): node IDs whose rows get the rooms'
      # tables (room/*/asterism/<host>$*).
      "room_hosts" => [],
      # The bridge's Asterism node ID (the console's inbox for files, T4b).
      "console_node" => "console",
      # The users' browsers with a certificate (T8): [{"name", "receives",
      # "receivers_managed"}] (or names alone).
      "browser_certs" => []
    }.freeze
    # The transfer keys (T8): refused to the shared ws/ subject.
    TRANSFER_KEYS = [ "asterism/*/transfer", "asterism/*/transfer/**" ].freeze
    # Every Asterism call, whoever the caller.
    ALL_CALLS = "asterism/*/*/*/call/**".freeze

    attr_reader :peers, :settings, :roles

    # peers: [{ "name", "kind" ("router"/"client"), "rw" => [keys], "ro" => [keys],
    #           "admin_space" => bool, "in_acl" => bool,
    #           "roles" => [role names], "nodes" => [node IDs] }]
    # roles: [{ "name", "templates" => { "rw" => [...], "read" => [...],
    #           "ask" => [...], "watch" => [...] }, "for_browsers" => bool }]
    def initialize(peers, settings = {}, roles: [])
      @settings = DEFAULTS.merge(settings.transform_keys(&:to_s))
      @roles = roles.map { _1.transform_keys(&:to_s) }.to_h { [ _1["name"], _1 ] }
      seats = seat_certificates.to_set { _1[2] }
      @browsers = Array(@settings["browser_certs"]).map { _1.is_a?(Hash) ? _1.transform_keys(&:to_s) : { "name" => _1.to_s } }
                                                   .uniq { _1["name"] }.sort_by { _1["name"] }
      taken = seats | @browsers.to_set { _1["name"] }
      @peers = peers.map { _1.transform_keys(&:to_s) }
                    .select { _1["in_acl"] && _1["name"] != @settings["name"] && !taken.include?(_1["name"]) }
                    .sort_by { _1["name"] }
      @sends = sender_keys
    end

    def self.ident(name)
      name.to_s.gsub(/[^A-Za-z0-9_]/, "_")
    end

    # A template with ${node} put in for each node (a template without it
    # once).
    def self.expand(templates, nodes)
      templates.flat_map { |t| t.include?(VARIABLE) ? nodes.map { |n| t.gsub(VARIABLE, n) } : [ t ] }.uniq
    end

    # A room slot's key space (G2).
    def self.room_keys(slot)
      [ "room/#{slot}/**", "room/#{slot}/**/@adv/**" ]
    end

    # What a seat or a host reads in a room (slot, or * for every room): the
    # key space and the nodes' profiles (** does not match @profile).
    def self.room_view(slot)
      [ *room_keys(slot), "room/#{slot}/asterism/*/@profile" ]
    end

    # A node's own place in a room (slot or *).
    def self.room_node_keys(slot, node)
      base = "room/#{slot}/asterism/#{node}"
      [ base, "#{base}/**", "#{base}/@profile", "#{base}/**/@adv/**" ]
    end

    # A call in a room under node's name.
    def self.room_call_key(slot, node) = "room/#{slot}/asterism/*/*/*/call/#{node}"

    def seat_node(slot, seat) = "#{@settings['seat_node_prefix']}#{slot}#{seat}"

    # [[slot, seat, certificate name], ...] in order.
    def seat_certificates
      @settings["room_seats"].to_h.sort.flat_map do |slot, seats|
        Array(seats).sort.map { [ slot.to_s, _1.to_s, "room-#{slot}-s#{_1}" ] }
      end
    end

    def room_hosts = Array(@settings["room_hosts"])

    def self.node_bound?(template)
      template.include?(VARIABLE)
    end

    def to_h
      name = @settings["name"]
      {
        "mode" => "router",
        "metadata" => { "name" => name },
        "listen" => { "endpoints" => [ *Array(@settings["listen"]), *Array(@settings["browsers"]) ] },
        "scouting" => { "multicast" => { "enabled" => false }, "gossip" => { "enabled" => false } },
        "transport" => {
          "unicast" => {
            "max_sessions" => @settings["max_sessions"].to_i,
            "accept_pending" => @settings["accept_pending"].to_i,
            "accept_timeout" => @settings["accept_timeout_ms"].to_i
          },
          "link" => {
            "rx" => { "max_message_size" => @settings["max_message_size"].to_i },
            "tls" => {
              "root_ca_certificate" => @settings["ca"],
              "listen_certificate" => format(@settings["certificate"], name: name),
              "listen_private_key" => format(@settings["private_key"], name: name),
              "enable_mtls" => true,
              "close_link_on_expiration" => true
            }
          }
        },
        "adminspace" => { "enabled" => true, "permissions" => { "read" => true, "write" => false } },
        "access_control" => access_control
      }
    end

    def access_control
      rules = []
      subjects = []
      policies = []
      shared = {}
      @peers.each do |p|
        id = self.class.ident(p["name"])
        mine = []
        rw = Array(p["rw"]).uniq
        ro = Array(p["ro"]).uniq - rw
        unless rw.empty?
          rules << { "id" => "#{id}_rw", "messages" => ALL, "flows" => %w[egress ingress],
                     "permission" => "allow", "key_exprs" => rw }
          mine << "#{id}_rw"
        end
        unless ro.empty?
          rules << { "id" => "#{id}_ro_in", "messages" => READ_IN, "flows" => %w[ingress],
                     "permission" => "allow", "key_exprs" => ro }
          rules << { "id" => "#{id}_ro_out", "messages" => ALL, "flows" => %w[egress],
                     "permission" => "allow", "key_exprs" => ro }
          mine.push("#{id}_ro_in", "#{id}_ro_out")
        end
        mine.concat(role_rules(rules, shared, id, Array(p["roles"]), nodes_of(p)))
        mine.concat(file_rules(rules, id, p))
        if p["admin_space"]
          ids = p["kind"] == "router" ? %w[admin_relay_in admin_relay_out] : %w[admin_read]
          ids.each { shared[_1] = true }
          mine.concat(ids)
        end
        if p["name"] == @settings["console"]
          mine.concat(profile_rules(rules, id))
          mine.concat(app_profile_rules(rules, id))
          mine.concat(rooms_watch_rules(rules, id))
        end
        mine.concat(room_host_rules(rules, id, p["name"])) if room_hosts.include?(p["name"])
        next if mine.empty?
        mine << subscribers_rule(shared)
        subjects << { "id" => id, "cert_common_names" => [ p["name"] ] }
        policies << { "id" => id, "rules" => mine, "subjects" => [ id ] }
      end
      seat_certificates.each { seat_rules(*_1, rules, subjects, policies, shared) }
      @browsers.each { browser_cert_rules(_1, rules, subjects, policies, shared) }
      if @settings["browsers"]
        mine = role_rules(rules, shared, "browsers", browser_role_names, [ @settings["browser_nodes"] ])
        unless mine.empty?
          rules << { "id" => "browsers__no_transfer", "messages" => ALL, "flows" => %w[egress ingress],
                     "permission" => "deny", "key_exprs" => TRANSFER_KEYS }
          mine << "browsers__no_transfer"
          mine << subscribers_rule(shared)
          subjects << { "id" => "browsers", "link_protocols" => [ "ws" ] }
          policies << { "id" => "browsers", "rules" => mine, "subjects" => [ "browsers" ] }
        end
      end
      rules.concat(shared.values.grep(Hash))
      rules << { "id" => "admin_read", "messages" => %w[query reply], "flows" => %w[egress ingress],
                 "permission" => "allow", "key_exprs" => [ "@/**" ] } if shared["admin_read"]
      if shared["admin_relay_in"]
        rules << { "id" => "admin_relay_in", "messages" => %w[declare_queryable reply], "flows" => %w[ingress],
                   "permission" => "allow", "key_exprs" => [ "@/**" ] }
        rules << { "id" => "admin_relay_out", "messages" => %w[query], "flows" => %w[egress],
                   "permission" => "allow", "key_exprs" => [ "@/**" ] }
      end
      { "enabled" => true, "default_permission" => "deny", "rules" => rules, "subjects" => subjects,
        "policies" => policies }
    end

    # The shared rule of the subscribers' declarations (once in shared);
    # its id.
    def subscribers_rule(shared)
      shared["subscribers_out"] ||= SUBSCRIBERS_RULE.merge("key_exprs" => SUBSCRIBERS.dup)
      "subscribers_out"
    end

    # The console's reading of the nodes' profiles (asterism/<node>/@profile)
    # and the publishing of its own (asterism/<console node>/@profile only):
    # the rules (pushed onto rules) and their ids.
    def profile_rules(rules, id)
      own = [ "asterism/#{@settings['console_node']}/@profile" ]
      list = [
        [ "profiles_in", PROFILES_IN, %w[ingress], [ PROFILES ] ],
        [ "profiles_out", PROFILES_OUT, %w[egress], [ PROFILES ] ],
        [ "own_profile_in", OWN_PROFILE_IN, %w[ingress], own ],
        [ "own_profile_out", OWN_PROFILE_OUT, %w[egress], own ]
      ]
      list.map do |suffix, messages, flows, keys|
        rid = "#{id}__#{suffix}"
        rules << { "id" => rid, "messages" => messages, "flows" => flows, "permission" => "allow", "key_exprs" => keys }
        rid
      end
    end

    # The console's reading of the applications' own profiles (protocol 2:
    # asterism/<node>/<app>/@profile, @status, @pubs) and of the shared
    # places: the rules and their ids.
    def app_profile_rules(rules, id)
      list = [
        [ "app_profiles_in", APP_PROFILES_IN, %w[ingress], [ APP_PROFILES ] ],
        [ "app_profiles_out", APP_PROFILES_OUT, %w[egress], [ APP_PROFILES ] ],
        [ "app_notices_in", APP_NOTICES_IN, %w[ingress], APP_NOTICES ],
        [ "app_notices_out", APP_NOTICES_OUT, %w[egress], APP_NOTICES ],
        [ "shared_in", SHARED_IN, %w[ingress], SHARED_PLACES ],
        [ "shared_out", SHARED_OUT, %w[egress], SHARED_PLACES ]
      ]
      list.map do |suffix, messages, flows, keys|
        rid = "#{id}__#{suffix}"
        rules << { "id" => rid, "messages" => messages, "flows" => flows, "permission" => "allow", "key_exprs" => keys }
        rid
      end
    end

    # The console's watch of the rooms (when there are seats): the
    # rules (pushed onto rules) and their ids.
    def rooms_watch_rules(rules, id)
      return [] unless rooms?
      rules << { "id" => "#{id}__rooms_in", "messages" => ROOMS_IN, "flows" => %w[ingress],
                 "permission" => "allow", "key_exprs" => [ ROOMS_WATCH ] }
      rules << { "id" => "#{id}__rooms_out", "messages" => ROOMS_OUT, "flows" => %w[egress],
                 "permission" => "allow", "key_exprs" => [ ROOMS_WATCH ] }
      [ "#{id}__rooms_in", "#{id}__rooms_out" ]
    end

    def rooms?
      seat_certificates.any?
    end

    # A seat (room-01-s03): the room to read, its own node to write, calls
    # under its own node ID only (two subjects, see the top of this file).
    # The slot's shared rules are added once (kept in shared).
    def seat_rules(slot, seat, name, rules, subjects, policies, shared)
      id = self.class.ident(name)
      node = seat_node(slot, seat)
      base = "room_#{slot}_seats"
      view = self.class.room_view(slot)
      shared["#{base}_in"] ||= { "id" => "#{base}_in", "messages" => ROOM_READ_IN, "flows" => %w[ingress],
                                 "permission" => "allow", "key_exprs" => view }
      shared["#{base}_get"] ||= { "id" => "#{base}_get", "messages" => %w[query], "flows" => %w[ingress],
                                  "permission" => "allow", "key_exprs" => view }
      shared["#{base}_out"] ||= { "id" => "#{base}_out", "messages" => ALL, "flows" => %w[egress],
                                  "permission" => "allow", "key_exprs" => view }
      shared["#{base}_no_calls"] ||= { "id" => "#{base}_no_calls", "messages" => %w[query], "flows" => %w[ingress],
                                       "permission" => "deny", "key_exprs" => [ "room/#{slot}/asterism/*/*/*/call/**" ] }
      rules << { "id" => "#{id}_own", "messages" => OWN, "flows" => %w[ingress], "permission" => "allow",
                 "key_exprs" => self.class.room_node_keys(slot, node) }
      rules << { "id" => "#{id}_call", "messages" => %w[query], "flows" => %w[ingress], "permission" => "allow",
                 "key_exprs" => [ self.class.room_call_key(slot, node) ] }
      subjects << { "id" => id, "cert_common_names" => [ name ] }
      subjects << { "id" => "#{id}_calls", "cert_common_names" => [ name ], "link_protocols" => [ "tls" ] }
      policies << { "id" => id, "rules" => [ "#{base}_in", "#{base}_get", "#{base}_out", "#{base}_no_calls", "#{id}_own" ],
                    "subjects" => [ id ] }
      policies << { "id" => "#{id}_calls", "rules" => [ "#{id}_call" ], "subjects" => [ "#{id}_calls" ] }
    end

    def browser_role_names = @roles.values.select { _1["for_browsers"] }.map { _1["name"] }

    # A user's browser with a certificate (T8): its roles with ${node} its
    # own name and no call under another name (subject id), the calls its
    # roles allow and its sends, as itself (subject id_calls, tls). See the
    # top of this file.
    def browser_cert_rules(b, rules, subjects, policies, shared)
      name = b["name"]
      id = "browser__#{self.class.ident(name)}"
      mine = role_rules(rules, shared, id, browser_role_names, [ name ])
      rules << { "id" => "#{id}__no_calls", "messages" => %w[query], "flows" => %w[ingress], "permission" => "deny",
                 "key_exprs" => [ ALL_CALLS ] }
      mine << "#{id}__no_calls"
      mine << subscribers_rule(shared)
      if b["receivers_managed"]
        mine.concat(section_rules(rules, "#{id}__receives_files", "rw", transfer_keys([ name ])))
      end
      subjects << { "id" => id, "cert_common_names" => [ name ] }
      policies << { "id" => id, "rules" => mine, "subjects" => [ id ] }
      calls = browser_calls(name)
      mine = []
      unless calls.empty?
        rules << { "id" => "#{id}__calls", "messages" => %w[query], "flows" => %w[ingress], "permission" => "allow",
                   "key_exprs" => calls }
        mine << "#{id}__calls"
      end
      sends = Array(@sends[name])
      mine.concat(section_rules(rules, "#{id}__sends_files", "ask", sends)) unless sends.empty?
      return if mine.empty?
      subjects << { "id" => "#{id}_calls", "cert_common_names" => [ name ], "link_protocols" => [ "tls" ] }
      policies << { "id" => "#{id}_calls", "rules" => mine, "subjects" => [ "#{id}_calls" ] }
    end

    # The calls the browsers' roles let a page make (their ask lines that
    # are calls), with the caller made the page's own name.
    def browser_calls(name)
      @roles.values.select { _1["for_browsers"] }.flat_map do |role|
        self.class.expand(Array(role.dig("templates", "ask")), [ name ]).filter_map do |key|
          base = key[%r{\A(.*/call)/[^/]+\z}, 1] or next
          "#{base}/#{name}"
        end
      end.uniq.sort
    end

    # The rules of one file section (FILE_SECTION_RULES) under prefix:
    # pushed onto rules; returns their ids.
    def section_rules(rules, prefix, section, keys)
      FILE_SECTION_RULES[section].map do |rsuffix, messages, flows|
        rule_id = "#{prefix}_#{rsuffix}"
        rules << { "id" => rule_id, "messages" => messages, "flows" => flows, "permission" => "allow",
                   "key_exprs" => keys }
        rule_id
      end
    end

    # A game host in the rooms (when there are seats): the rules
    # (pushed onto rules) and their ids.
    def room_host_rules(rules, id, name)
      return [] unless rooms?
      own = "#{name}$*"
      view = self.class.room_view("*")
      list = [
        [ "own", OWN, %w[ingress], self.class.room_node_keys("*", own) ],
        [ "in", ROOM_READ_IN, %w[ingress], view ],
        [ "ask", %w[query], %w[ingress], [ self.class.room_call_key("*", own), "room/*/asterism/*/*/*/meta",
                                            "room/*/asterism/*/@profile" ] ],
        [ "out", ALL, %w[egress], view ]
      ]
      list.map do |suffix, messages, flows, keys|
        rid = "#{id}__room_host_#{suffix}"
        rules << { "id" => rid, "messages" => messages, "flows" => flows, "permission" => "allow", "key_exprs" => keys }
        rid
      end
    end

    # The lines of the two marks for files with the console (T4b):
    # [[suffix, section, keys], ...] for one peer (as RelayPeer#to_config).
    def file_lines(peer)
      nodes = nodes_of(peer)
      console = @settings["console_node"]
      lines = []
      if peer["files_to_console"]
        lines << [ "files_to_console", "ask", nodes.map { "asterism/#{console}/transfer/inbox/call/#{_1}" } ]
      end
      if peer["files_from_console"]
        lines << [ "files_from_console", "rw", transfer_keys(nodes) ]
      end
      lines << [ "receives_files", "rw", transfer_keys(nodes) ] if peer["receivers_managed"]
      sends = Array(@sends[peer["name"]])
      lines << [ "sends_files", "ask", sends ] unless sends.empty?
      lines
    end

    def transfer_keys(nodes) = nodes.flat_map { [ "asterism/#{_1}/transfer", "asterism/#{_1}/transfer/**" ] }

    # A node ID against a receiver's entry (a node ID, or a pattern with *).
    def self.receiver_match?(entry, node)
      entry == node || (entry.include?("*") && File.fnmatch?(entry, node))
    end

    # {sender row's name => [ask keys]}: for every row in the ACL whose
    # lists name (or match) a node of a row (another row's, or another node
    # behind the same home router), the inbox calls of its nodes under those
    # senders' names (T6). A node is not its own sender.
    def sender_keys
      out = Hash.new { |h, k| h[k] = [] }
      # [name, nodes, receives]: the rows, and the browsers with a
      # certificate (T8), which send and receive like a row of their own.
      parties = @peers.map { [ _1["name"], nodes_of(_1), _1["receives"] ] } +
                @browsers.map { [ _1["name"], [ _1["name"] ], _1["receives"] ] }
      parties.each do |_, receivers, receives|
        entries = Hash(receives).values.flatten.map(&:to_s).uniq
        next if entries.empty?
        parties.each do |sname, snodes, _|
          snodes.each do |sn|
            next unless entries.any? { self.class.receiver_match?(_1, sn) }
            receivers.each { |rn| out[sname] << "asterism/#{rn}/transfer/inbox/call/#{sn}" unless rn == sn }
          end
        end
      end
      out.transform_values(&:uniq).transform_values(&:sort)
    end

    # The rules of a mark's section: an ask line also lets the replies to
    # those calls reach the caller (above).
    FILE_SECTION_RULES = SECTION_RULES.merge(
      "ask" => [ *SECTION_RULES["ask"], [ "answer", %w[reply], %w[egress] ] ]
    ).freeze

    # The rules of those marks (pushed onto rules) and their ids.
    def file_rules(rules, id, peer)
      file_lines(peer).flat_map do |suffix, section, keys|
        FILE_SECTION_RULES[section].map do |rsuffix, messages, flows|
          rule_id = "#{id}__#{suffix}_#{rsuffix}"
          rules << { "id" => rule_id, "messages" => messages, "flows" => flows, "permission" => "allow",
                     "key_exprs" => keys }
          rule_id
        end
      end
    end

    # What one peer gets from its marks for files, for the pages:
    # [{ "mark", "section", "keys" }].
    def files_expansion(peer)
      file_lines(peer.transform_keys(&:to_s)).map { |mark, section, keys| { "mark" => mark, "section" => section, "keys" => keys } }
    end

    # The nodes a peer speaks for: the list, or its own name.
    def nodes_of(peer)
      nodes = Array(peer["nodes"]).uniq
      nodes.empty? ? [ peer["name"] ] : nodes
    end

    # The rules a subject (id) gets from its roles: the node-bound templates
    # as its own rules (pushed onto rules), the others as shared rules (kept
    # in shared under their id, added once). Returns the rule ids.
    def role_rules(rules, shared, id, role_names, nodes)
      mine = []
      role_names.uniq.sort.each do |rname|
        role = @roles[rname] or next
        rid = self.class.ident(rname)
        SECTIONS.each do |section|
          templates = Array(role.dig("templates", section)).uniq
          bound, fixed = templates.partition { self.class.node_bound?(_1) }
          SECTION_RULES[section].each do |suffix, messages, flows|
            unless bound.empty?
              rule_id = "#{id}__#{rid}_#{suffix}"
              rules << { "id" => rule_id, "messages" => messages, "flows" => flows, "permission" => "allow",
                         "key_exprs" => self.class.expand(bound, nodes) }
              mine << rule_id
            end
            next if fixed.empty?
            rule_id = "role__#{rid}_#{suffix}"
            shared[rule_id] ||= { "id" => rule_id, "messages" => messages, "flows" => flows,
                                  "permission" => "allow", "key_exprs" => fixed }
            mine << rule_id
          end
        end
      end
      mine
    end

    # What one peer (as RelayPeer#to_config) gets from its roles, for the
    # pages: [{ "role", "section", "keys" }].
    def expansion_for(peer)
      peer = peer.transform_keys(&:to_s)
      nodes = nodes_of(peer)
      Array(peer["roles"]).uniq.sort.flat_map do |rname|
        role = @roles[rname] or next []
        SECTIONS.filter_map do |section|
          keys = self.class.expand(Array(role.dig("templates", section)), nodes)
          { "role" => rname, "section" => section, "keys" => keys } unless keys.empty?
        end
      end
    end

    def body
      self.class.dump(to_h) + "\n"
    end

    # JSON (so JSON5 too), indented, with lists of plain values on one line.
    def self.dump(v, indent = "")
      inner = "#{indent}  "
      case v
      when Hash
        return "{}" if v.empty?
        "{\n" + v.map { |k, x| "#{inner}#{JSON.generate(k.to_s)}: #{dump(x, inner)}" }.join(",\n") + "\n#{indent}}"
      when Array
        return "[#{v.map { JSON.generate(_1) }.join(', ')}]" if v.none? { _1.is_a?(Hash) || _1.is_a?(Array) }
        "[\n" + v.map { "#{inner}#{dump(_1, inner)}" }.join(",\n") + "\n#{indent}]"
      else
        JSON.generate(v)
      end
    end

    # A digest of the configuration itself (not of the header's time).
    def digest
      Digest::SHA256.hexdigest(body)[0, 16]
    end

    def text(by: nil, at: Time.now.utc)
      HEADER + "// Made #{at.strftime('%Y-%m-%d %H:%M:%S UTC')}#{" by #{by}" if by}, digest #{digest}.\n" + body
    end

    # The names the ACL lets in (subjects with a policy), from a generated
    # file (or nil when there is none / it is not one of ours).
    def self.subjects_of(text)
      return nil if text.nil?
      json = JSON.parse(text.lines.reject { _1.lstrip.start_with?("//") }.join)
      json.dig("access_control", "subjects").to_a.flat_map { _1["cert_common_names"].to_a }.uniq.sort
    rescue JSON::ParserError
      nil
    end

    def subject_names
      to_h.dig("access_control", "subjects").flat_map { _1["cert_common_names"].to_a }.uniq.sort
    end
  end
end
