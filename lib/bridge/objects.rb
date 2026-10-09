# What runs the page's meta and call requests on the object layer, through
# Asterism's public API (a proxy per path and time limit) rather than the
# module's internal Asterism.meta / Asterism.call. Time limits in seconds.
# The tests pass a stand-in with the same two methods.
module Bridge
  class Objects
    # {"methods" => [[name, arity], ...]}, fetched again on every request
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
      Asterism[path, timeout: timeout]
    end
  end
end
