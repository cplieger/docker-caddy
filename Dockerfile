# check=error=true
FROM --platform=$BUILDPLATFORM caddy:2.11-builder@sha256:47a19b0d310d09e226e9d7b9bcfb4bcc8fa7480d8903e2ebd40fa1512b9ce38c AS builder
ENV GOTOOLCHAIN=auto

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=$TARGETOS GOARCH=$TARGETARCH xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4 \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.12.1

FROM caddy:2.11@sha256:ec18ee54aab3315c22e25f3b2babda73ff8007d39b13b3bd1bfffa2f0444c7d9

COPY --chmod=755 --from=builder /usr/bin/caddy /usr/bin/caddy
# Default healthcheck; private homelab compose overrides with tighter
# timing (15s/5s/5/30s) for VRRP failover detection.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD wget -q --spider http://127.0.0.1:80/health || exit 1
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
