# A CRuby node for checking a server after it is set up (docs/install.md,
# "Check"): connects to the router over mutual TLS with a row's
# certificate, joins an app its roles allow (default "game", the app of the
# example role "match"), exposes <app>/board, lists the objects of the app
# it sees and calls board.move on every other node's board. Run two of them
# to see a call cross the router. Needs the asterism gem.
#
#   # the .tar the console's certificate page saved ("Save all (.tar)"):
#   # router and node from it (asterism with credentials:, after 0.7.0)
#   ruby check_node.rb --credentials alice.tar [--app game] [--serve 60]
#   # the three files (asterism 0.7.0 and later)
#   ruby check_node.rb --router tls/router.example.org:7448 --node alice \
#     --ca ca.pem --cert alice.pem --key alice.key [--app game] [--serve 60]
#
# With a role that allows calls only under the caller's own name, a --node
# other than the certificate's name (or a node the row does not speak for)
# can still read, but its calls get no answer (nobody answers).
require "asterism"
require "optparse"

opt = { app: "game", serve: 30.0 }
OptionParser.new do |o|
  o.on("--credentials TAR", "the console's .tar (in place of the other four)") { |v| opt[:credentials] = v }
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--node ID", "the node ID (its certificate's name, or a node its row speaks for)") { |v| opt[:node] = v }
  o.on("--ca FILE") { |v| opt[:ca] = v }
  o.on("--cert FILE") { |v| opt[:cert] = v }
  o.on("--key FILE") { |v| opt[:key] = v }
  o.on("--app NAME", "the app (default game)") { |v| opt[:app] = v }
  o.on("--serve SECONDS", Float, "stay this long answering calls (default 30)") { |v| opt[:serve] = v }
end.parse!
%i[router node ca cert key].each { |k| abort "--#{k} is required" unless opt[k] } unless opt[:credentials]

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S')} #{text}"
  $stdout.flush
end

class Board
  def initialize(name) = @name = name
  def move(x, y) = "#{@name} took #{x},#{y} for #{Asterism.current_call&.from}"
end

how = if opt[:credentials]
  { credentials: opt[:credentials] }
else
  { config: { "transport/link/tls/root_ca_certificate" => opt[:ca],
              "transport/link/tls/connect_certificate" => opt[:cert],
              "transport/link/tls/connect_private_key" => opt[:key],
              "transport/link/tls/enable_mtls" => true } }
end
Asterism.connect(opt[:router], node: opt[:node], app: opt[:app], **how) do |net|
  opt[:node] = net.node_id
  net.expose("board", Board.new(opt[:node]), methods: { move: 2 })
  net.on_join { |n| log("joined: #{n}") }
  net.on_leave { |n| log("left: #{n}") }
  net.start
  log("#{opt[:node]}/#{opt[:app]} connected#{" to #{opt[:router]}" if opt[:router]}")
  sleep 3
  log("#{opt[:app]} objects: #{net.each("*/#{opt[:app]}/*").map(&:asterism_path).sort.join(' ')}")
  net.each("*/#{opt[:app]}/board").map { _1.asterism_path.split("/")[0] }.each do |n|
    next if n == opt[:node]
    r = net["#{n}/#{opt[:app]}/board"].move(3, 4) rescue "#{$!.class}: #{$!.message[0, 100]}"
    log("#{n}/#{opt[:app]}/board.move(3, 4) -> #{r.inspect}")
  end
  sleep opt[:serve]
  net.stop
end
