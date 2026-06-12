# check=error=true
FROM caddy:2.11-builder@sha256:ea6e54f62d2033b80747b022923ae0dd4f817ec4eefa2ca3a34cbebf16b6468c AS builder
ENV GOTOOLCHAIN=auto

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    xcaddy build \
        --with github.com/caddy-dns/cloudflare@v0.2.4 \
        --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.12.1

FROM caddy:2.11@sha256:cfeb0b281bc44a5a51fecde39e9e577c60d863c0b6196e6bbdf58fd00960887f

COPY --chmod=755 --from=builder /usr/bin/caddy /usr/bin/caddy
# Liveness probe against Caddy's admin API (enabled by default on
# 127.0.0.1:2019), so the image is healthy out of the box for ANY Caddyfile.
# For an end-to-end check that verifies the proxy actually serves traffic,
# override this in your compose to probe a /health route — see Caddyfile.example
# and the README. Override the interval/timeout/retries there too.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD wget -qO- http://127.0.0.1:2019/config/ >/dev/null 2>&1 || exit 1
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
