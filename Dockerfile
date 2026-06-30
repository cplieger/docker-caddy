# check=error=true
FROM caddy:2.11-builder@sha256:26f5271c26850df54ef7a9f3704b5d688c1ad51b5cde509c9d011b4e95cc8397 AS builder
ENV GOTOOLCHAIN=auto

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    xcaddy build \
        --with github.com/caddy-dns/cloudflare@v0.2.4 \
        --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.13.1

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test against the freshly built binary:
# both bundled plugins must be compiled in (the xcaddy failure mode) and the
# shipped example Caddyfile must validate. A failure here fails the centralized
# `ci / validate` docker build gate, because the final stage depends on this
# stage's marker.
# ---------------------------------------------------------------------------
FROM builder AS test
COPY tests/ /tmp/tests/
COPY Caddyfile.example /tmp/tests/Caddyfile.example
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

FROM caddy:2.11@sha256:af5fdcd76f2db5e4e974ee92f96ee8c0fc3edb55bd4ba5032547cbf3f65e486d

# Patch the runtime base's OS packages for Alpine security fixes that upstream's
# caddy image has not rebuilt for yet (notably openssl libssl3/libcrypto3). Caddy
# is a static Go binary and never links OpenSSL, but the packages ship in the base
# and are flagged by image scanners; upgrading keeps the published image clean.
#
# tzdata: the upstream caddy:2.11 Alpine base ships no zoneinfo, and the
# xcaddy-built binary dropped Go's embedded tz database, so the TZ env var
# (e.g. TZ=Europe/Paris) is silently ignored without it. Installing tzdata
# makes TZ honored for log timestamps and time-based config.
# hadolint ignore=DL3017
RUN apk upgrade --no-cache \
    && apk add --no-cache tzdata

COPY --chmod=755 --from=builder /usr/bin/caddy /usr/bin/caddy
# Force the test stage to build and pass before the runtime image is produced.
COPY --from=test /tests-passed /tests-passed
# Liveness probe against Caddy's admin API (enabled by default on
# 127.0.0.1:2019), so the image is healthy out of the box for ANY Caddyfile.
# For an end-to-end check that verifies the proxy actually serves traffic,
# override this in your compose to probe a /health route — see Caddyfile.example
# and the README. Override the interval/timeout/retries there too.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD wget -qO- http://127.0.0.1:2019/config/ >/dev/null 2>&1 || exit 1
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
