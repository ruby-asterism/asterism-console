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
# it.
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
      "room_hosts" => []
    }.freeze

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
      @peers = peers.map { _1.transform_keys(&:to_s) }
                    .select { _1["in_acl"] && _1["name"] != @settings["name"] && !seats.include?(_1["name"]) }
                    .sort_by { _1["name"] }
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
        if p["admin_space"]
          ids = p["kind"] == "router" ? %w[admin_relay_in admin_relay_out] : %w[admin_read]
          ids.each { shared[_1] = true }
          mine.concat(ids)
        end
        if p["name"] == @settings["console"]
          mine.concat(profile_rules(rules, id))
          mine.concat(rooms_watch_rules(rules, id))
        end
        mine.concat(room_host_rules(rules, id, p["name"])) if room_hosts.include?(p["name"])
        next if mine.empty?
        subjects << { "id" => id, "cert_common_names" => [ p["name"] ] }
        policies << { "id" => id, "rules" => mine, "subjects" => [ id ] }
      end
      seat_certificates.each { seat_rules(*_1, rules, subjects, policies, shared) }
      if @settings["browsers"]
        names = @roles.values.select { _1["for_browsers"] }.map { _1["name"] }
        mine = role_rules(rules, shared, "browsers", names, [ @settings["browser_nodes"] ])
        unless mine.empty?
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

    # The console's reading of the nodes' profiles (asterism/<node>/@profile):
    # the rules (pushed onto rules) and their ids.
    def profile_rules(rules, id)
      rules << { "id" => "#{id}__profiles_in", "messages" => PROFILES_IN, "flows" => %w[ingress],
                 "permission" => "allow", "key_exprs" => [ PROFILES ] }
      rules << { "id" => "#{id}__profiles_out", "messages" => PROFILES_OUT, "flows" => %w[egress],
                 "permission" => "allow", "key_exprs" => [ PROFILES ] }
      [ "#{id}__profiles_in", "#{id}__profiles_out" ]
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
