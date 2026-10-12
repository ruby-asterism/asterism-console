# The store behind the controllers' rate limits (sign-in, invitations,
# passes). Production: the cache store (solid_cache, shared by every Puma
# process). Elsewhere a memory store of its own, so the limits also work in
# development and the tests (whose cache store is the null store).
module RateLimits
  STORE = Rails.env.production? ? Rails.cache : ActiveSupport::Cache::MemoryStore.new
end
