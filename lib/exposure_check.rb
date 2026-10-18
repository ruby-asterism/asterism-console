# The exposure check (0.3.6, docs/exposure.md): what a server answers to
# the outside, compared with what it should answer. bin/asterism-exposure
# runs it from a machine that is neither the server nor its admins' home
# (a scheduled GitHub Actions job in a private repository), so the
# provider's packet filter is part of what it sees.
#
# Plain Ruby (net/http, socket, yaml): no Rails, no bundle, so it runs on a
# bare ruby.
#
# The checks are a YAML file without any host name (it can be public); the
# hosts come from the environment (ASTERISM_EXPOSURE_HOST, and
# ASTERISM_EXPOSURE_HOST_<NAME> for a check with "host: <name>") or from
# --host. The output never names a host: it says <host> (or <name>), and
# any message that would carry a host's name or address is cut out.
#
#   checks:
#     - http: /invite             # GET, redirects not followed
#       status: 200               # one code or a list
#       body: "Make a room"       # optional: the body contains it
#     - asset_from: /invite       # an /assets/*.css or .js named in the page
#       status: 200
#     - tcp: 7443                 # a TCP connection
#       expect: open              # open | closed (a timeout or a refusal)
#       timeout: 5
require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"
require "yaml"

module ExposureCheck
  DEFAULT_TIMEOUT = 5
  HOST_ENV = "ASTERISM_EXPOSURE_HOST".freeze
  ASSET = %r{/assets/[A-Za-z0-9._~/-]+\.(?:css|js)(?=["'?#\s>)])}

  # IO::TimeoutError is Ruby 3.2's (Socket.tcp's connect_timeout).
  TIMEOUTS = [ Errno::ETIMEDOUT, Timeout::Error, (IO::TimeoutError if defined?(IO::TimeoutError)) ].compact.freeze

  class ConfigError < StandardError; end

  Result = Struct.new(:ok, :kind, :target, :expected, :actual, keyword_init: true) do
    def line
      format("%-4s  %-5s %-34s expected %-14s actual %s",
             ok ? "ok" : "FAIL", kind, target, expected, actual)
    end
  end

  module_function

  # The hosts by name ("default" for checks without "host:") from the
  # environment, then from --host [name=]value arguments.
  def hosts_from(env, args = [])
    hosts = {}
    env.each do |key, value|
      next if value.to_s.strip.empty?
      if key == HOST_ENV
        hosts["default"] = value.strip
      elsif key.start_with?("#{HOST_ENV}_")
        hosts[key.delete_prefix("#{HOST_ENV}_").downcase] = value.strip
      end
    end
    args.each do |arg|
      name, value = arg.include?("=") ? arg.split("=", 2) : [ "default", arg ]
      hosts[name.downcase] = value.strip
    end
    hosts
  end

  def load_config(path)
    data = YAML.safe_load_file(path)
    raise ConfigError, "#{path}: no list under \"checks\"" unless data.is_a?(Hash) && data["checks"].is_a?(Array)
    data
  rescue Psych::Exception => e
    raise ConfigError, "#{path}: #{e.message}"
  end

  # Runs every check; returns the results (it does not raise for a server
  # that does not answer: that is the check's failure).
  def run(config, hosts, connector: nil)
    defaults = config.reject { |k, _| k == "checks" }
    named = config["checks"].each_with_index.map do |check, i|
      raise ConfigError, "check #{i + 1} is not a map" unless check.is_a?(Hash)
      name = (check["host"] || "default").to_s.downcase
      raise ConfigError, "check #{i + 1}: no host \"#{name}\" (#{env_name(name)} or --host)" unless hosts[name]
      [ check, name ]
    end
    secrets = scrub_list(hosts.values)
    named.map do |check, name|
      Runner.new(defaults.merge(check), hosts[name], label(name), secrets, connector).call
    end
  end

  def env_name(name) = name == "default" ? HOST_ENV : "#{HOST_ENV}_#{name.upcase}"
  def label(name) = name == "default" ? "<host>" : "<#{name}>"

  # The hosts' names and their addresses, to cut out of any message.
  def scrub_list(hosts)
    @scrub_cache ||= {}
    hosts.flat_map do |h|
      @scrub_cache[h] ||= [ h ] + begin
        Addrinfo.getaddrinfo(h, nil, nil, :STREAM).map(&:ip_address).uniq
      rescue SocketError, SystemCallError
        []
      end
    end.uniq.sort_by { -_1.size }
  end

  def scrub(text, secrets, placeholder = "<host>")
    secrets.reduce(text.to_s) { |t, s| s.empty? ? t : t.gsub(s, placeholder) }
  end

  # The first /assets/...css or .js the page names.
  def asset_path(body)
    body.to_s[ASSET]
  end

  class Runner
    def initialize(check, host, label, secrets, connector)
      @c = check
      @host = host
      @label = label
      @secrets = secrets
      @connector = connector || method(:connect)
    end

    def call
      if @c.key?("http") then http_check
      elsif @c.key?("asset_from") then asset_check
      elsif @c.key?("tcp") then tcp_check
      else raise ConfigError, "a check needs http, asset_from or tcp: #{@c.keys.join(', ')}"
      end
    end

    private

    def timeout = (@c["timeout"] || DEFAULT_TIMEOUT).to_f
    def scheme = (@c["scheme"] || "https").to_s
    def port = (@c["port"] || (scheme == "https" ? 443 : 80)).to_i

    def default_port? = port == (scheme == "https" ? 443 : 80)
    def where(path) = "#{scheme}://#{@label}#{":#{port}" unless default_port?}#{path}"

    def statuses(default = nil)
      list = Array(@c.fetch("status", default)).map(&:to_i)
      raise ConfigError, "#{@c.inspect}: no status" if list.empty?
      list
    end

    def result(ok, kind, target, expected, actual)
      Result.new(ok: ok, kind: kind, target: target, expected: expected, actual: safe(actual))
    end

    def safe(text) = ExposureCheck.scrub(text, @secrets, @label)

    def http_check
      path = @c["http"].to_s
      want = statuses
      body_want = @c["body"]
      expected = want.join("|") + (body_want ? " +body" : "")
      res = get(path)
      return result(false, "http", where(path), expected, res) if res.is_a?(String)
      ok = want.include?(res.code.to_i)
      actual = res.code.to_s
      if ok && body_want && !res.body.to_s.include?(body_want.to_s)
        ok = false
        actual += " (body lacks the text)"
      end
      actual += " -> #{location(res)}" if res["location"] && !ok
      result(ok, "http", where(path), expected, actual)
    end

    def asset_check
      page = @c["asset_from"].to_s
      want = statuses(200)
      expected = want.join("|")
      res = get(page)
      return result(false, "asset", where("#{page} -> asset"), expected, "page: #{res}") if res.is_a?(String)
      unless res.code.to_i == 200
        return result(false, "asset", where("#{page} -> asset"), expected, "page answered #{res.code}")
      end
      asset = ExposureCheck.asset_path(res.body)
      return result(false, "asset", where("#{page} -> asset"), expected, "no /assets/*.css|js in the page") unless asset
      res = get(asset)
      return result(false, "asset", where(asset), expected, res) if res.is_a?(String)
      result(want.include?(res.code.to_i), "asset", where(asset), expected, res.code.to_s)
    end

    def tcp_check
      tcp_port = @c["tcp"].to_i
      expect = (@c["expect"] || "open").to_s
      raise ConfigError, "tcp #{tcp_port}: expect is open or closed, not #{expect}" unless %w[open closed].include?(expect)
      outcome = begin
        @connector.call(@host, tcp_port, timeout)
        "open"
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        "refused"
      rescue *TIMEOUTS
        "timeout"
      rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH
        "unreachable"
      rescue SocketError
        "name not resolved"
      rescue SystemCallError, IOError => e
        e.class.name
      end
      ok = expect == "open" ? outcome == "open" : %w[refused timeout unreachable].include?(outcome)
      result(ok, "tcp", "#{@label}:#{tcp_port}", expect, outcome)
    end

    def connect(host, port, timeout)
      Socket.tcp(host, port, connect_timeout: timeout).close
    end

    # A response, or a String saying why there is none. Never follows a
    # redirect.
    def get(path)
      http = Net::HTTP.new(@host, port)
      http.use_ssl = scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.ssl_timeout = timeout
      http.max_retries = 0
      http.start { |h| h.request(Net::HTTP::Get.new(path, "User-Agent" => "asterism-exposure")) }
    rescue OpenSSL::SSL::SSLError => e
      "tls error (#{e.message.sub(/\ASSL_connect returned=\d+ errno=\d+ /, '').sub(/peeraddr=\S+ /, '')})"
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      "refused"
    rescue Net::OpenTimeout, Net::ReadTimeout, *TIMEOUTS
      "timeout"
    rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH
      "unreachable"
    rescue SocketError
      "name not resolved"
    rescue StandardError => e
      e.class.name
    end

    # A redirect's target, its host replaced (never printed).
    def location(res)
      uri = URI.parse(res["location"])
      return uri.path.to_s unless uri.host
      host = @secrets.include?(uri.host) ? @label : "<another host>"
      "#{uri.scheme}://#{host}#{uri.path}"
    rescue URI::InvalidURIError
      "(a location)"
    end
  end
end
