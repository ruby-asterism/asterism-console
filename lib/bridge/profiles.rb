# The nodes' profiles (V2.5, asterism 0.5.0's Asterism.profile): what each
# Asterism node says it is (kind, host, name) and its icon.
#
# How the bridge learns them (Runner#sync_profiles, #profile_worker):
#   - a node that appears is asked once, without the icon
#     (Asterism.profile_of(node, icon: false)); when its icon_hash is not in
#     the icon store (NodeIcon), it is asked again with the icon, which is
#     kept by its hash. Nodes with the same icon share one row: the icon
#     crosses the network once per icon, not once per node.
#   - a node puts its profile without the icon on asterism/<node>/@profile
#     at connect and on each change: that notice replaces what is known
#     (the last change wins when several applications of one node answer
#     differently), and fetches the icon when its hash is new.
#   - a node that does not answer (an older version, or a ROS 2 bridge that
#     is not Asterism) keeps the V2.2 marks by its name; it is not asked
#     again until it leaves and comes back.
#   - a node that leaves is forgotten (asked again when it comes back).
#
# The graph gets {node => summary} (Graph.build profiles:), the summary
# being the profile without the icon bytes; Marks turns it into the mark
# and the icon's URL. Thread-safe: the notices come on the receiving
# thread, the answers on the worker.
module Bridge
  class Profiles
    FIELDS = %w[protocol kind host name icon_hash].freeze

    def initialize(icons: nil)
      @lock = Mutex.new
      @known = {}   # node => summary Hash, or false (asked, no profile)
      @asking = {}  # node => true while queued or asked
      @icons = icons # Set of the icon hashes in the store (nil: read it once)
    end

    def clear
      @lock.synchronize do
        @known.clear
        @asking.clear
      end
    end

    # The summary of a profile Hash (Asterism::Profile.check's form).
    def self.summary(profile)
      return nil unless profile.is_a?(Hash) && profile["kind"]
      profile.slice(*FIELDS)
    end

    # The nodes to ask now, given the Asterism nodes on the network: the
    # new ones, marked as being asked. The ones gone are forgotten.
    def due(nodes)
      @lock.synchronize do
        (@known.keys - nodes).each { @known.delete(_1) }
        (@asking.keys - nodes).each { @asking.delete(_1) }
        nodes.reject { @known.key?(_1) || @asking.key?(_1) }.each { @asking[_1] = true }
      end
    end

    # An answer to profile_of (nil: no answer). Returns true when the graph
    # changes.
    def answered(node, profile)
      s = self.class.summary(profile)
      @lock.synchronize do
        @asking.delete(node)
        old = @known[node]
        @known[node] = s || false
        old != @known[node] && (s || old)
      end ? true : false
    end

    # A notice put on asterism/<node>/@profile (already checked). Returns
    # true when the graph changes.
    def told(node, profile)
      s = self.class.summary(profile)
      return false unless s
      @lock.synchronize do
        old = @known[node]
        @known[node] = s
        old != s
      end
    end

    # Whether the store has the icon of this hash.
    def icon?(hash)
      return false unless hash
      icons.include?(hash)
    end

    # Keeps an icon (bytes checked by Asterism::Profile.check) in the store.
    def keep_icon(hash, png, width, height)
      NodeIcon.keep(hash, png, width, height)
      @lock.synchronize { icons << hash }
    end

    # {node => summary} of the nodes that have one.
    def to_graph
      @lock.synchronize { @known.select { |_, s| s }.transform_values(&:dup) }
    end

    # The icon hashes the store has (for the graph's icon URLs).
    def icon_set
      @lock.synchronize { icons.dup }
    end

    private

    def icons
      @icons ||= NodeIcon.pluck(:icon_hash).to_set
    rescue ActiveRecord::ActiveRecordError
      @icons = Set.new
    end
  end
end
