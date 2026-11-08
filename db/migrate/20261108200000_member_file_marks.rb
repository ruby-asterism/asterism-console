# Files with the console per member (T4b, docs/files.md): a row of the
# relay registry has two marks, "may send files to the console"
# (files_to_console) and "receives files from the console"
# (files_from_console). The cloud router's ACL lines for them are made from
# the registry (Relay::CloudConfig) and the bridge reads its senders and its
# receivers from them.
#
# They take the place of 0.3.13's two settings:
#   - the call permissions of kind "file" ("Allow sending files"): each row's
#     node pattern marks the registry rows that speak for a node it matches
#     (files_from_console); then the file rows go, and the column kind with
#     them (every row left is a call);
#   - ASTERISM_TRANSFER_FROM (.env, read here when it is still set): its
#     patterns mark the rows the same way (files_to_console). The console
#     reads it no more.
# A pattern that matches no registry row is said in the migration's output
# (and the log): nothing is marked for it.
class MemberFileMarks < ActiveRecord::Migration[8.1]
  class Peer < ActiveRecord::Base
    self.table_name = "relay_peers"

    def speaks_for
      list = nodes.to_s.lines.map(&:strip).reject(&:empty?)
      list.empty? ? [ name ] : list
    end
  end

  class Permission < ActiveRecord::Base
    self.table_name = "call_permissions"
  end

  def up
    add_column :relay_peers, :files_to_console, :boolean, null: false, default: false
    add_column :relay_peers, :files_from_console, :boolean, null: false, default: false
    Peer.reset_column_information
    Permission.reset_column_information

    Permission.where(kind: "file").order(:id).each do |row|
      mark(row.node, :files_from_console, "call permission \"Allow sending files\" #{row.node}")
      row.destroy!
    end
    ENV["ASTERISM_TRANSFER_FROM"].to_s.split(/[\s,]+/).reject(&:empty?).each do |pattern|
      mark(pattern, :files_to_console, "ASTERISM_TRANSFER_FROM #{pattern}")
    end
    remove_column :call_permissions, :kind
  end

  def down
    add_column :call_permissions, :kind, :string, null: false, default: "call"
    Permission.reset_column_information
    Peer.where(files_from_console: true).order(:name).each do |p|
      p.speaks_for.each do |n|
        Permission.create!(kind: "file", node: n, app: "transfer", object: "inbox", method_name: "*",
                           note: "from the member #{p.name}")
      end
    end
    remove_column :relay_peers, :files_to_console
    remove_column :relay_peers, :files_from_console
  end

  private

  def mark(pattern, column, what)
    re = Regexp.new("\\A#{Regexp.escape(pattern.to_s).gsub('\\*', '[^/]*')}\\z")
    peers = Peer.order(:name).select { |p| p.speaks_for.any? { re.match?(_1) } }
    if peers.empty?
      line = "#{what}: no member row speaks for a node it matches; nothing marked (mark the rows in Admin > Members)"
      say line
      Rails.logger.warn("migration T4b: #{line}")
      return
    end
    peers.each { _1.update_columns(column => true) }
    say "#{what}: marked #{column} on #{peers.map(&:name).join(', ')}"
  end
end
