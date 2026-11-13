# What runs the page's meta and call requests on the object layer, through
# Asterism's public API (a proxy per path and time limit) rather than the
# connection's internal meta / call. Time limits in seconds. The tests pass
# a stand-in with the same two methods.
module Bridge
  class Objects
    # net: the bridge's connection (an Asterism::Connection), or a callable
    # giving it (the bridge connects again after losing its router).
    def initialize(net)
      @net = net
    end

    # {"methods" => [{"name" => name, "arity" => n}, ...]} (protocol 1),
    # fetched again on every request
    # (the object may have been exposed again since). The page wants the
    # arities, so this is the proxy's meta rather than remote_methods.
    def meta(path, timeout:)
      proxy(path, timeout).asterism_refresh.asterism_meta
    end

    # Calls name on path. Through the proxy's method_missing, so that a
    # remote method named like one of the proxy's own (to_s, inspect,
    # class, send ...) is still the remote one, and never runs in here.
    def call(path, name, args, kwargs, timeout:)
      sym = name.to_s.to_sym
      raise ArgumentError, "#{name} cannot be called through a proxy" if Asterism::Proxy::LOCAL_ONLY.include?(sym)
      proxy(path, timeout).method_missing(sym, *args, **kwargs)
    end

    private

    def proxy(path, timeout)
      net = @net.is_a?(Proc) ? @net.call : @net
      raise Asterism::Disconnected, "the bridge is not connected" unless net
      net[path, timeout: timeout]
    end
  end
end
