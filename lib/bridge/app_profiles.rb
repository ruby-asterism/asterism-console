# The applications' own profiles (asterism protocol 2, docs/protocol.md 8
# of the asterism gem): what each application tells about itself at
# asterism/<node>/<app>/@profile.
#
#   status  a small map it tells and puts again on .../@status when it
#           changes (a game host: its tables' counts)
#   pubs    the topics it streams ({name => {"t", "e", "u", "d", "ts"}}),
#           put again on .../@pubs when they change
#   types   its own types' definitions ({name => {"f" => [...], "d"}}),
#           answered only (no put)
#
# The graph shows them in the details of the app and of its node (nothing
# drawn changes); the recorder takes a key's declaration and the types it
# names for the channel's schema (Bridge::Recorder).
#
# How the bridge learns them (Runner#sync_app_profiles, #status_notice,
# #pubs_notice):
#   - an application that appears (its token, or an object's) is asked
#     once, on the profile worker: one get of its profile with the
#     parameters status;pubs;types (no answer: nothing to show, not asked
#     again until it leaves and comes back);
#   - its puts on @status and @pubs replace those parts; a put on @pubs
#     that names a type of its own not known yet asks again (the types
#     have no put of their own);
#   - an application that leaves (its liveliness token, and its objects',
#     go away) is forgotten, with what it declared: its last put on @pubs
#     outlives it (on a shared place in particular, where nothing else
#     says the sender is gone), so the graph's lines to the shared places
#     and the recorder's schemas would keep a dead sender. A put or an
#     answer from an application that is not here (it left, or its token
#     is not seen yet) is not kept: the get made when its token appears
#     brings the same parts.
#
# The reading is the asterism gem's (Asterism::Status.check,
# Asterism::Pubs.check, Asterism::Types.check). Thread-safe: the puts come
# on the receiving thread, the answers on the worker, the graph and the
# recorder read on others.
module Bridge
  class AppProfiles
    PARTS = %w[status pubs types].freeze
    # The parameters of the one get each application is asked.
    PARAMS = PARTS.join(";").freeze

    def initialize
      @lock = Mutex.new
      @known = {}  # "node/app" => { "status" => .., "pubs" => .., "types" => .. }, or false (asked, no answer)
      @asking = {} # "node/app" => true while queued or asked
      @alive = {}  # "node/app" => true: here, as the last due saw them
    end

    def clear
      @lock.synchronize do
        @known.clear
        @asking.clear
        @alive.clear
      end
    end

    # The parts of an answer to the get, cleaned: {"status", "pubs",
    # "types"} with the parts that passed (an empty Hash when it answered
    # without any), or nil when it is not a map. node: the application's
    # node (a declaration on another node's shared place is dropped).
    def self.check(raw, node = nil)
      return nil unless raw.is_a?(Hash)
      out = {}
      st = ::Asterism::Status.check(raw["status"])
      out["status"] = st if st
      pubs = ::Asterism::Pubs.check(raw["pubs"], node)
      out["pubs"] = pubs if pubs && !pubs.empty?
      types = ::Asterism::Types.check(raw["types"])
      out["types"] = types if types && !types.empty?
      out
    end

    # [node/app, status] of a put on asterism/<node>/<app>/@status, or nil.
    def self.parse_status(key, payload)
      node, app, st = ::Asterism::Status.parse(key, payload.to_s)
      node ? [ "#{node}/#{app}", st ] : nil
    rescue StandardError
      nil
    end

    # [node/app, declarations] of a put on asterism/<node>/<app>/@pubs, or nil.
    def self.parse_pubs(key, payload)
      node, app, pubs = ::Asterism::Pubs.parse(key, payload.to_s)
      node ? [ "#{node}/#{app}", pubs ] : nil
    rescue StandardError
      nil
    end

    # The applications to ask now, given those on the network: the new ones,
    # marked as being asked. The ones gone are forgotten.
    def due(apps)
      @lock.synchronize do
        @alive = apps.to_h { [ _1, true ] }
        (@known.keys - apps).each { @known.delete(_1) }
        (@asking.keys - apps).each { @asking.delete(_1) }
        apps.reject { @known.key?(_1) || @asking.key?(_1) }.each { @asking[_1] = true }
      end
    end

    # Marks an application known to be asked again (a put on @pubs named a
    # type not known yet). True when it is to be queued (not being asked).
    def ask_again(app)
      @lock.synchronize do
        next false if @asking.key?(app) || !@alive[app]
        @asking[app] = true
      end
    end

    # An answer to the get (raw: the decoded reply, nil when none came).
    # True when the graph changes.
    def answered(app, raw)
      parts = raw.nil? ? nil : self.class.check(raw, app.to_s.split("/").first)
      @lock.synchronize do
        @asking.delete(app)
        next false unless @alive[app] # it left while being asked
        old = @known[app]
        @known[app] = parts && !parts.empty? ? parts : (parts ? {} : false)
        (old || {}) != (@known[app] || {})
      end
    end

    # A put on @status (already checked). True when the graph changes.
    def told_status(app, status) = told(app, "status", status)

    # A put on @pubs (already checked): [the graph changes, a type it names
    # is not known (ask again)].
    def told_pubs(app, pubs)
      changed = told(app, "pubs", pubs.empty? ? nil : pubs)
      missing = @lock.synchronize do
        types = @known[app] ? @known[app]["types"].to_h : {}
        pubs.values.any? { |d| d["t"].is_a?(String) && !types.key?(d["t"]) }
      end
      [ changed, missing ]
    end

    # {"node/app" => {"status", "pubs", "types"}} of the applications that
    # told something.
    def to_graph
      @lock.synchronize do
        @known.select { |_, p| p && !p.empty? }.transform_values { |p| deep_dup(p) }
      end
    end

    # The declaration of the topic on a data key (asterism/<node>/<app>/<name>,
    # the name may hold "/") and the definitions of the types it names
    # (with those their fields name): [declaration, {type name => definition}],
    # or nil when the application did not declare it (or is not known).
    # A key of a shared place (Bridge::Shared: asterism/<node>/@shared/<name>,
    # asterism/@shared/<name>) has no owner: its sender (from, "<node>/<app>",
    # the value's attachment) declared it under the key's entry, and the
    # types are read from that sender's definitions (the same type name may
    # be defined differently by another sender).
    def topic(key, from: nil)
      parts = key.to_s.split("/")
      return nil unless parts.size >= 3 && parts[0] == ::Asterism::ROOT
      if Shared.key?(key)
        return nil unless from
        app = from
        name = parts[1..].join("/")
      else
        return nil unless parts.size >= 4
        app = "#{parts[1]}/#{parts[2]}"
        name = parts[3..].join("/")
      end
      @lock.synchronize do
        p = @known[app]
        decl = p && p["pubs"]&.[](name)
        return nil unless decl
        [ decl.dup, self.class.definitions(decl["t"], p["types"].to_h) ]
      end
    end

    # The definitions a type name needs: its own and those of the types its
    # fields name, as far as types has them. {} for a built-in type (a
    # number) or none.
    def self.definitions(name, types)
      out = {}
      todo = [ name ]
      until todo.empty?
        t = todo.shift
        next unless t.is_a?(String)
        t = t.delete_suffix("[]")
        next if out.key?(t) || !types.key?(t)
        out[t] = types[t]
        Array(types[t]["f"]).each { |f| todo << f[1] if f.is_a?(Array) }
      end
      out
    end

    private

    def told(app, part, value)
      @lock.synchronize do
        next false unless @alive[app]
        p = @known[app] ? @known[app].dup : {}
        old = p[part]
        value.nil? ? p.delete(part) : p[part] = value
        @known[app] = p
        old != value
      end
    end

    def deep_dup(v)
      case v
      when Hash then v.to_h { |k, x| [ k, deep_dup(x) ] }
      when Array then v.map { deep_dup(_1) }
      else v
      end
    end
  end
end
