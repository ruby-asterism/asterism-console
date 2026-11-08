# The bridge's side of files (T4, docs/files.md; FileTransfer rows).
#
#   - Receiving: an Asterism::Transfer::FileInbox in FileTransfer.inbox,
#     answering at <console>/transfer/inbox (Asterism::Transfer::Endpoint on
#     the bridge's Zenoh connection: the object layer's application is
#     "console", and the machines send to <node>/transfer/inbox). It takes
#     files from the nodes of the members marked "may send files to the
#     console" (RelayPeer.file_senders, T4b; read again every FROM_EVERY
#     seconds, so a mark takes effect without restarting), up to
#     FileTransfer::INBOX_MAX in all. Each file is a row: "receiving" at its
#     begin, then "done", "refused" (its sha256 did not match) or "dropped"
#     (cancelled by its sender, or no piece for a minute). A begin refused
#     (a node not allowed, a name, no room) is a "refused" row too, once a
#     minute per node and reason.
#   - Sending: a "pending" send row (to a node of a member marked
#     "receives files from the console", RelayPeer.file_receivers) is sent
#     by an Asterism::Transfer::Sender on a thread of its own (it steps every STEP seconds: the main loop's
#     tick would give a piece window every 0.1 s), at most MAX_SENDING at
#     once. The main loop writes the progress and the end into the row and
#     passes the page's Cancel on.
#
# The receiving thread answers the inbox's calls; what they change goes to
# the database from the main loop (sync), through a queue.
module Bridge
  class Transfers
    MAX_SENDING = 2
    STEP = 0.002
    # A pending row the bridge did not take within this time ends.
    PENDING_FOR = 120
    # The same refused begin (node and reason) is recorded once per this many seconds.
    REFUSALS_EVERY = 60
    # The senders allowed (the members' marks) are read again this often.
    FROM_EVERY = 2

    # What the inbox and the senders log goes to the bridge's lines.
    class Log
      def initialize(say) = (@say = say)
      def info(text) = @say.call("bridge: files: #{text.to_s.delete_prefix('transfer: ')}")
      def warn(text) = info(text)
    end

    attr_reader :inbox, :endpoint
    # What sends a file (the tests give a Sender whose calls go elsewhere).
    attr_writer :sender_class

    # from: the senders allowed, a callable giving node IDs (or patterns
    # with *); by default the registry's marks.
    def initialize(conn:, node:, say:, from: -> { RelayPeer.file_senders })
      @conn = conn
      @node = node
      @say = say
      @from_source = from
      @from = Array(from.call)
      @from_at = monotonic
      @events = Queue.new
      @sends = {}  # row id => { thread:, sender:, cancel:, done:, error: }
      @receiving = {} # inbox file id => row id
      @refusals = {}
      @log = Log.new(say)
    end

    def start
      require "asterism/transfer"
      @inbox = self.class.inbox_class.new(FileTransfer.inbox.to_s, work: FileTransfer.work.to_s, from: @from,
                                          max_bytes: FileTransfer::INBOX_MAX, label: @node)
      @inbox.events = @events
      @inbox.logger = @log
      @inbox.start
      @endpoint = Asterism::Transfer::Endpoint.new(@conn, @inbox, node: @node).start
      take_up_held
      @say.call("bridge: files: answering at #{@endpoint.path}, from #{from_text}")
      if ENV["ASTERISM_TRANSFER_FROM"].present?
        @say.call("bridge: files: ASTERISM_TRANSFER_FROM is not read since 0.3.14: the members' marks in " \
                  "Admin > Members say who may send (delete it from .env)")
      end
      self
    end

    # The FileInbox that tells what happens (made once Asterism is loaded:
    # Puma never loads it).
    def self.inbox_class
      @inbox_class ||= Class.new(Asterism::Transfer::FileInbox) do
        attr_accessor :events

        def begin(kind, meta, from: nil)
          before = current_file && current_file["id"]
          r = super
          t = current_file
          @events << [ :begin, Transfers.facts(t), Time.current ] if t && t["id"] != before
          r
        rescue Asterism::Transfer::Refused => e
          m = meta.is_a?(Hash) ? meta : {}
          @events << [ :refused, { "from" => from, "name" => m["name"], "size" => m["size"], "sha256" => m["sha256"],
                                   "meta" => m, "kind" => kind }, e.message ]
          raise
        end

        def commit(id, from: nil)
          before = last_done
          r = super
          d = last_done
          @events << [ :commit, Transfers.facts(d["t"]), r, Time.current ] if d && !d.equal?(before)
          r
        end

        def drop(why)
          t = current_file
          @events << [ :dropped, Transfers.facts(t), why ] if t
          super
        end
      end
    end

    def self.facts(t)
      { "id" => t["id"], "from" => t["from"], "kind" => t["kind"], "name" => t["name"], "size" => t["size"],
        "sha256" => t["sha256"], "meta" => t["meta"], "got" => t["got"] }
    end

    # The main loop, every SYNC_EVERY.
    def sync
      refresh_from
      @endpoint&.tick
      take_events
      report_receiving
      sync_sends
    rescue ActiveRecord::ActiveRecordError => e
      @say.call("bridge: files: #{e.message}")
    end

    def close
      @sends.each_value { _1[:cancel] = true }
      @sends.each_value { _1[:thread]&.join(3) }
      @sends.each do |id, e|
        FileTransfer.where(id: id, status: FileTransfer::ACTIVE).find_each do |row|
          finish_send(row, e, stopped: true)
        end
      rescue ActiveRecord::ActiveRecordError, StandardError => err
        @say.call("bridge: files: #{id}: #{err.class}: #{err.message}")
      end
      @sends.clear
      @endpoint&.close
      @endpoint = nil
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def from_text = @from.empty? ? "nobody (no member is marked to send files to the console)" : @from.join(" ")

    # The members' marks, read again every FROM_EVERY seconds; the inbox
    # checks a begin against them.
    def refresh_from(now: false)
      return if !now && monotonic - @from_at < FROM_EVERY
      @from_at = monotonic
      list = Array(@from_source.call)
      return if list == @from
      @from = list
      @endpoint ? @endpoint.synchronize { @inbox.from = list } : (@inbox&.from = list)
      @say.call("bridge: files: taking files from #{from_text}")
    end

    # ---------------------------------------------------------- receiving

    # A file held when the bridge last stopped goes on in its row.
    def take_up_held
      t = @endpoint.synchronize { @inbox.current_file && Transfers.facts(@inbox.current_file) }
      rows = FileTransfer.receives.where(status: "receiving").order(:id).to_a
      held = t && rows.reverse.find { _1.node == t["from"] && _1.name == t["name"] && _1.sha256 == t["sha256"] }
      @receiving[t["id"]] = held.id if held
      (rows - [ held ]).each do |r|
        r.update!(status: "dropped", reason: "the bridge stopped while it came", finished_at: Time.current)
      end
    end

    def take_events
      loop do
        ev = @events.pop(true)
        case ev[0]
        when :begin then received_begin(ev[1], ev[2])
        when :commit then received_commit(ev[1], ev[2], ev[3])
        when :dropped then received_dropped(ev[1], ev[2])
        when :refused then received_refused(ev[1], ev[2])
        end
      end
    rescue ThreadError
      nil
    end

    def received_begin(t, at)
      row = FileTransfer.create!(direction: "receive", status: "receiving", node: t["from"].to_s, name: t["name"].to_s,
                                 size: t["size"].to_i, sha256: t["sha256"], overwrite: t["meta"]["overwrite"] == true,
                                 done_bytes: t["got"].to_i, started_at: at)
      @receiving[t["id"]] = row.id
    end

    def row_for(t)
      id = @receiving.delete(t["id"])
      (id && FileTransfer.find_by(id: id)) ||
        FileTransfer.new(direction: "receive", node: t["from"].to_s, name: t["name"].to_s, size: t["size"].to_i,
                         sha256: t["sha256"], overwrite: t["meta"]["overwrite"] == true, started_at: Time.current)
    end

    def received_commit(t, answer, at)
      row = row_for(t)
      a = answer.is_a?(Hash) ? answer : {}
      if a["status"] == "placed"
        row.assign_attributes(status: "done", placed_name: a["name"], done_bytes: t["size"].to_i, reason: nil)
      else
        row.assign_attributes(status: "refused", reason: a["reason"].to_s)
      end
      row.finished_at = at
      row.took_ms = ((at - row.started_at) * 1000).round if row.started_at
      row.save!
    end

    def received_dropped(t, why)
      row = row_for(t)
      row.update!(status: "dropped", reason: why.to_s, done_bytes: t["got"].to_i, finished_at: Time.current)
    end

    def received_refused(t, why)
      key = [ t["from"], why ]
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @refusals[key] && now - @refusals[key] < REFUSALS_EVERY
      @refusals[key] = now
      @refusals.delete_if { |_, at| now - at > REFUSALS_EVERY }
      FileTransfer.create!(direction: "receive", status: "refused", node: safe_node(t["from"]),
                           name: t["name"].is_a?(String) && !t["name"].empty? ? t["name"].scrub[0, 255] : "?",
                           size: t["size"].is_a?(Integer) ? t["size"] : 0,
                           sha256: t["sha256"].is_a?(String) ? t["sha256"][0, 64] : nil,
                           reason: why.to_s, finished_at: Time.current)
    end

    def safe_node(n)
      FileTransfer::NODE.match?(n.to_s) ? n.to_s : "unknown"
    end

    def report_receiving
      t = @endpoint&.synchronize { @inbox.current_file && [ @inbox.current_file["id"], @inbox.current_file["got"] ] }
      return unless t
      id = @receiving[t[0]]
      FileTransfer.where(id: id, status: "receiving").update_all(done_bytes: t[1], updated_at: Time.current) if id
    end

    # ------------------------------------------------------------ sending

    def sync_sends
      rows = FileTransfer.sends.where(status: %w[pending sending cancelling]).order(:id).to_a
      rows.each do |row|
        e = @sends[row.id]
        case row.status
        when "pending"
          if row.created_at < PENDING_FOR.seconds.ago
            row.update!(status: "failed", reason: "the bridge did not take it in time", finished_at: Time.current)
            FileUtils.rm_f(row.outbox_path) if row.outbox_path
          elsif e.nil? && @sends.size < MAX_SENDING
            start_send(row)
          end
        when "sending", "cancelling"
          if e.nil?
            row.update!(status: "failed", reason: "the bridge stopped while it was sending", finished_at: Time.current)
            FileUtils.rm_f(row.outbox_path) if row.outbox_path
          elsif e[:done]
            finish_send(row, e)
          else
            e[:cancel] = true if row.status == "cancelling"
            pos = e[:sender]&.pos
            row.update_columns(done_bytes: pos, updated_at: Time.current) if pos && pos != row.done_bytes
          end
        end
      end
      # a row that went (deleted) while its file was on its way
      (@sends.keys - rows.map(&:id)).each do |id|
        e = @sends[id]
        e[:cancel] = true
        @sends.delete(id) if e[:done]
      end
    end

    def start_send(row)
      # The page checked the permission when it wrote the row; again here
      # (a row may have been removed since).
      unless RelayPeer.receives_files?(row.node)
        row.update!(status: "denied", reason: "no member row lets the console send files to #{row.node} (checked by the bridge)",
                    finished_at: Time.current)
        FileUtils.rm_f(row.outbox_path) if row.outbox_path
        return
      end
      path = row.outbox_path
      unless path && File.file?(path)
        row.update!(status: "failed", reason: "the uploaded file is gone", finished_at: Time.current)
        return
      end
      meta = {}
      meta["overwrite"] = true if row.overwrite
      meta["inbox"] = "sd" if row.sd
      e = { cancel: false, done: false, sender: nil, error: nil }
      log = @log
      to = "#{row.node}/transfer/inbox"
      e[:thread] = Thread.new do
        s = (@sender_class || Asterism::Transfer::Sender).new(to, "file", path.to_s, name: row.name, meta: meta, sha256: row.sha256)
        s.logger = log
        e[:sender] = s
        until s.done?
          if e[:cancel]
            s.cancel
            break
          end
          s.step
          sleep STEP
        end
      rescue StandardError => err
        e[:error] = "#{err.class}: #{err.message}"
      ensure
        e[:done] = true
      end
      @sends[row.id] = e
      row.update!(status: "sending", started_at: Time.current)
      @say.call("bridge: files: sending #{row.name} (#{row.size} bytes) to #{to} for " \
                "#{row.user&.email_address || '?'}#{row.overwrite ? ', overwrite' : ''}#{row.sd ? ', SD' : ''}")
    end

    def finish_send(row, e, stopped: false)
      @sends.delete(row.id)
      s = e[:sender]
      attrs = { finished_at: Time.current }
      if s
        attrs.merge!(done_bytes: s.pos, took_ms: s.took_ms, piece: s.piece, window: s.window)
      end
      a = s&.ok? ? (s.answer.is_a?(Hash) ? s.answer : {}) : nil
      if a && a["status"].to_s == "placed"
        attrs.merge!(status: "done", placed_name: a["name"].to_s, done_bytes: row.size, reason: nil)
      elsif stopped
        attrs.merge!(status: "failed", reason: "the bridge stopped while it was sending")
      elsif s&.cancelled?
        attrs.merge!(status: "cancelled", reason: "cancelled; #{row.node} dropped what it held")
      else
        attrs.merge!(status: "failed", reason: (a ? a["reason"] : s&.reason) || e[:error] || "stopped")
      end
      row.update!(attrs)
      FileUtils.rm_f(row.outbox_path) if row.outbox_path
      @say.call("bridge: files: #{row.name} to #{row.node}: #{row.status}" \
                "#{row.placed_name.present? ? " as #{row.placed_name}" : ''}#{row.reason.present? ? " (#{row.reason})" : ''}" \
                "#{row.took_ms ? format(' in %.0f ms', row.took_ms) : ''}")
    end
  end
end
