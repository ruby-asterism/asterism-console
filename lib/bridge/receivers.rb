require "set"

# Who each machine receives files from (0.3.16, T6, docs/files.md): the
# bridge sends a member row's lists (RelayPeer#receivers_payload) to the
# transfer app of each node the row speaks for, by calling
# <node>/transfer/inbox policy_set as the console's node. The machine keeps
# them in the managed part of its /home/asterism/receive.toml (written only
# when they changed) and decides on that copy, also while the console
# cannot be reached.
#
# When: the row's lists changed (their digest is not the one the node last
# took), the node's transfer app appeared on the network (again), and every
# AGAIN_EVERY seconds while it stays; after a failure, again in
# RETRY_EVERY. One call at a time, on a thread of its own (a machine that
# does not answer waits TIMEOUT); the main loop writes what each node got
# into the row (receivers_delivered) and says a change in the log.
#
# A user's browser with a certificate (T8, User's lists, its node
# wasm-<handle>) is sent its list the same way: the browser build takes it
# when the door connected the page with the user's certificate.
#
# A machine refuses the list over a connection without certificates (its
# router is not tls/): the row then shows the machine's reason. A machine
# whose receiving is off (enabled in its receive.toml) keeps the list but
# takes nothing: it says so in its answer ("receiving" => false), and its
# transfer app is usually not running at all (then the list waits).
module Bridge
  class Receivers
    AGAIN_EVERY = 600
    RETRY_EVERY = 30
    TIMEOUT = 10
    # the rows are read this often
    READ_EVERY = 2
    APP = "transfer".freeze

    # call: what sends one list (node, payload) -> the machine's answer;
    # the tests give a stand-in.
    def initialize(say:, call: nil)
      @say = say
      @call = call || ->(node, payload) { Asterism["#{node}/#{APP}/inbox", timeout: TIMEOUT].policy_set(payload) }
      @jobs = Queue.new
      @results = Queue.new
      @last = {}       # node => { digest:, at: (monotonic), ok: }
      @pending = Set.new
      @present = Set.new
      @read_at = nil
    end

    def start
      @worker = Thread.new { work }
      @worker.name = "receivers" if @worker.respond_to?(:name=)
      self
    end

    def close
      @jobs << nil
      @worker&.join(TIMEOUT + 1)
      @worker = nil
    end

    # From the main loop: apps are the "node/app" here now.
    def sync(apps, now: monotonic)
      take_results
      present = apps.filter_map { |a| n, app = a.split("/", 2); n if app == APP }.to_set
      appeared = present - @present
      @present = present
      return if @read_at && now - @read_at < READ_EVERY && appeared.empty?
      @read_at = now
      (RelayPeer.managed.to_a + User.managed.to_a).each do |row|
        digest = row.receivers_digest
        row.receiver_nodes.each do |node|
          next unless present.include?(node) && !@pending.include?(node)
          st = @last[node]
          due = st.nil? || st[:digest] != digest || appeared.include?(node) ||
                now - st[:at] >= (st[:ok] ? AGAIN_EVERY : RETRY_EVERY)
          next unless due
          @pending << node
          @last[node] = { digest: digest, at: now, ok: false }
          @jobs << [ [ row.class.name, row.id ], node, row.receivers_payload, digest ]
        end
      end
    rescue ActiveRecord::ActiveRecordError => e
      @say.call("bridge: receivers: #{e.message}")
    end

    # Waits until what is queued now has been sent (the tests).
    def drain(timeout: 5)
      deadline = monotonic + timeout
      sleep 0.01 until (@jobs.empty? && @results.size >= @pending.size) || monotonic >= deadline
      take_results
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def work
      while (job = @jobs.pop)
        row_id, node, payload, digest = job
        begin
          answer = @call.call(node, payload)
          @results << [ row_id, node, digest, true, answer, nil ]
        rescue StandardError => e
          msg = e.respond_to?(:remote_message) ? e.remote_message : "#{e.class}: #{e.message}"
          @results << [ row_id, node, digest, false, nil, msg.to_s[0, 300] ]
        end
      end
    end

    def take_results
      until @results.empty?
        row_id, node, digest, ok, answer, error = @results.pop
        @pending.delete(node)
        st = @last[node]
        st[:ok] = ok if st && st[:digest] == digest
        record(row_id, node, digest, ok, answer, error)
      end
    end

    # row_id: [class name, id] (a member row, or a user for its browser).
    def record(row_id, node, digest, ok, answer, error)
      kind, id = row_id
      row = { "RelayPeer" => RelayPeer, "User" => User }.fetch(kind).find_by(id: id) or return
      all = row.delivered
      before = all[node] || {}
      now = Time.current.utc.iso8601
      all[node] = if ok
        got = { "digest" => digest, "at" => now }
        # a Family mruby machine says whether it receives at all (its
        # receive.toml's enabled, T7); the list is kept there either way
        got["receiving"] = answer["receiving"] if answer.is_a?(Hash) && [ true, false ].include?(answer["receiving"])
        got
      else
        before.except("error", "tried_at").merge("error" => error, "tried_at" => now)
      end
      row.update_column(:receivers_delivered, JSON.generate(all))
      if ok
        written = answer.is_a?(Hash) && answer["written"]
        if written || before["digest"] != digest || before["error"]
          whose = row.is_a?(User) ? "its user" : row.name
          @say.call("bridge: receivers: #{node} has the list of #{whose}#{written ? ' (written there)' : ''}")
        end
      elsif before["error"] != error
        @say.call("bridge: receivers: #{node}: not delivered: #{error}")
      end
    end
  end
end
