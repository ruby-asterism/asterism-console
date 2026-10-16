# The console's image (ghcr.io/ruby-asterism/asterism-console, published
# for each version by .github/workflows/image.yml, amd64 and arm64): Rails
# (Puma), the bridge, the signer and the browsers' door run from it, each
# as its own service of deploy/vps/docker-compose.yml. Built by hand from
# the repository's root:
#   docker build -f deploy/vps/Dockerfile -t asterism-console-local:0.1.0 .
#
# The Asterism gems come from rubygems.org (ASTERISM_GEMS=rubygems in the
# Gemfile); asterism-zenoh compiles its C extension against the zenoh-c
# release it pins, downloaded while the image is built.
ARG RUBY_VERSION=3.2.6
FROM ruby:${RUBY_VERSION}-slim AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl git libyaml-dev pkg-config unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    ASTERISM_GEMS=rubygems

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile && bundle exec bootsnap precompile app/ lib/

FROM ruby:${RUBY_VERSION}-slim

ARG CONSOLE_VERSION=dev
LABEL org.opencontainers.image.title="asterism-console" \
      org.opencontainers.image.description="Asterism Console: the graph, the relay registry and the router's ACL of an Asterism network" \
      org.opencontainers.image.source="https://github.com/ruby-asterism/asterism-console" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${CONSOLE_VERSION}"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libsqlite3-0 libyaml-0-2 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    ASTERISM_GEMS=rubygems

WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# The console and the bridge run as "rails" (1000); the signer as "signer"
# (1001), whose CA directory (/ca, a volume) nobody else mounts or reads.
RUN groupadd --system --gid 1000 rails && useradd --uid 1000 --gid 1000 --create-home rails && \
    groupadd --system --gid 1001 signer && useradd --uid 1001 --gid 1001 --no-create-home signer && \
    mkdir -p /ca /generated /certs /backups /rooms /seats storage tmp log && \
    chown signer:signer /ca && chmod 0700 /ca && \
    chown -R rails:rails /generated /certs /backups /rooms /seats storage tmp log db
USER 1000:1000

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
