# The applications' statuses (0.3.4, asterism's asterism/<node>/<app>/@status):
# a small map each application tells about itself and puts again when it
# changes (a game host: its tables' counts). The graph shows it in the
# details of the app, and of its node; it changes nothing that is drawn.
#
# How the bridge learns them (Runner#sync_statuses, #status_notice):
#   - an application that appears (its token, or an object's) is asked
#     once, on the profile worker (a get on its key; no answer: no status,
#     not asked again until it leaves and comes back);
#   - its puts on the key replace what is known;
#   - an application that leaves is forgotten.
#
# The reading is asterism's (docs/protocol.md 8.4): a map, the entries with
# a non-empty str key, 1024 bytes at most packed. Done here rather than by
# Asterism::Status, which the released asterism 0.7.1 does not have yet.
# Thread-safe: the puts come on the receiving thread, the answers on the
# worker.
module Bridge
  class Statuses
    MAX_BYTES = 1024

    def initialize
      @lock = Mutex.new
      @known = {}  # "node/app" => status Hash, or false (asked, no status)
      @asking = {} # "node/app" => true while queued or asked
    end

    def clear
      @lock.synchronize do
        @known.clear
        @asking.clear
      end
    end

    # A received status, cleaned, or nil.
    def self.check(raw)
      return nil unless raw.is_a?(Hash)
      out = raw.select { |k, _| k.is_a?(String) && !k.empty? }
      MessagePack.pack(out).bytesize > MAX_BYTES ? nil : out
    rescue StandardError
      nil
    end

    # [node/app, status] of a put on asterism/<node>/<app>/@status, or nil.
    def self.parse(key, payload)
      parts = key.to_s.split("/")
      return nil unless parts.size == 4 && parts[0] == "asterism" && parts[3] == "@status"
      st = check(MessagePack.unpack(payload.to_s))
      st ? [ "#{parts[1]}/#{parts[2]}", st ] : nil
    rescue StandardError
      nil
    end

    # The applications to ask now, given those on the network: the new ones,
    # marked as being asked. The ones gone are forgotten.
    def due(apps)
      @lock.synchronize do
        (@known.keys - apps).each { @known.delete(_1) }
        (@asking.keys - apps).each { @asking.delete(_1) }
        apps.reject { @known.key?(_1) || @asking.key?(_1) }.each { @asking[_1] = true }
      end
    end

    # An answer to the get (nil: no answer). True when the graph changes.
    def answered(app, status)
      @lock.synchronize do
        @asking.delete(app)
        old = @known[app]
        @known[app] = status || false
        old != @known[app] && (status || old) ? true : false
      end
    end

    # A put on the key (already checked). True when the graph changes.
    def told(app, status)
      @lock.synchronize do
        old = @known[app]
        @known[app] = status
        old != status
      end
    end

    # {"node/app" => status} of the applications that have one.
    def to_graph
      @lock.synchronize { @known.select { |_, s| s }.transform_values(&:dup) }
    end
  end
end
