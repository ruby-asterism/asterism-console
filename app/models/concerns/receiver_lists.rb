# Who a receiver takes files from (0.3.16, T6, docs/files.md): two lists,
# one per kind (receive_files_from: "file", receive_checkpoints_from:
# "checkpoint"), of node IDs and patterns ("fmruby-*", "*"), one per line.
# The bridge sends them to the receiver's nodes (Bridge::Receivers; their
# transfer app writes them into the managed part of receive.toml), and the
# ACL lets the senders call those nodes' inboxes (Relay::CloudConfig).
# receivers_changed_at is when they last changed (the machines keep it with
# their copy); a receiver that has one is "managed": its nodes keep their
# transfer keys in the ACL, so an emptied list still reaches them.
# receivers_delivered is the bridge's record of what each node got (JSON).
#
# A member row (RelayPeer) has them for the nodes it speaks for, a user
# (T8) for the browser page with the user's certificate (wasm-<handle>).
# The including class answers receiver_nodes.
module ReceiverLists
  extend ActiveSupport::Concern

  # The kinds a machine receives and their columns.
  RECEIVE_KINDS = { "file" => :receive_files_from, "checkpoint" => :receive_checkpoints_from }.freeze
  # A node ID or a pattern of them (* any run of letters), as the machines
  # match it (FmrbReceiveConf): letters, digits, . _ - and *.
  RECEIVER = /\A[A-Za-z0-9._\-*]{1,64}\z/
  RECEIVERS_MAX = 64

  included do
    # The form's choices (Edit): the nodes ticked and the other lines
    # (patterns, nodes not in the list), per kind. Setting either sets the
    # kind's column.
    RECEIVE_KINDS.each do |kind, column|
      define_method(:"#{column}_picked=") do |list|
        (@receive_form ||= {})[kind] ||= {}
        @receive_form[kind][:picked] = Array(list).map(&:to_s).map(&:strip).reject(&:empty?)
      end
      define_method(:"#{column}_more=") do |text|
        (@receive_form ||= {})[kind] ||= {}
        @receive_form[kind][:more] = ReceiverLists.lines(text)
      end
    end
    before_validation :take_receive_form
    before_save :mark_receivers_changed
    validate :receivers_are_names
  end

  def self.lines(text)
    text.to_s.lines.map(&:strip).reject(&:empty?)
  end

  # The senders its machines receive a kind from (node IDs and patterns).
  def receivers(kind)
    ReceiverLists.lines(self[RECEIVE_KINDS.fetch(kind.to_s)])
  end

  def receives_any?
    RECEIVE_KINDS.keys.any? { receivers(_1).any? }
  end

  # Its lists were ever chosen (its nodes are sent them, and keep their
  # transfer keys in the ACL).
  def managed_receivers?
    receivers_changed_at.present?
  end

  # What the bridge sends its nodes (their transfer app's policy_set).
  def receivers_payload
    { "file" => receivers("file"), "checkpoint" => receivers("checkpoint"),
      "at" => receivers_changed_at&.utc&.iso8601 }
  end

  def receivers_digest
    Digest::SHA256.hexdigest(JSON.generate(receivers_payload))[0, 16]
  end

  # {node => {"digest", "at" (delivered), "error", "tried_at"}}.
  def delivered
    JSON.parse(receivers_delivered.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  # What Relay::CloudConfig takes for the lists.
  def receives_config
    RECEIVE_KINDS.keys.to_h { [ _1, receivers(_1) ] }
  end

  private

  def take_receive_form
    return unless @receive_form
    @receive_form.each do |kind, f|
      list = (Array(f[:picked]) + Array(f[:more])).uniq
      self[RECEIVE_KINDS[kind]] = list.empty? ? nil : list.join("\n")
    end
    @receive_form = nil
  end

  def mark_receivers_changed
    changed = RECEIVE_KINDS.values.any? do |c|
      will_save_change_to_attribute?(c) && ReceiverLists.lines(attribute_in_database(c)) != ReceiverLists.lines(self[c])
    end
    self.receivers_changed_at = Time.current if changed
  end

  def receivers_are_names
    RECEIVE_KINDS.each_value do |column|
      list = ReceiverLists.lines(self[column])
      bad = list.reject { RECEIVER.match?(_1) }
      errors.add(column, "has lines that are not node IDs or patterns: #{bad.join(' ')}") if bad.any?
      errors.add(column, "has more than #{RECEIVERS_MAX} lines") if list.size > RECEIVERS_MAX
    end
  end
end
