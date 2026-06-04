# check=error=true
FROM --platform=$BUILDPLATFORM caddy:2.11-builder@sha256:f2b98918658f949a3c533f2c73bd0806e3f2576ccf8eb182c8b1690c977007ea AS builder
ENV GOTOOLCHAIN=auto

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=$TARGETOS GOARCH=$TARGETARCH xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4 \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.12.1

FROM caddy:2.11@sha256:a22e108570bde2bf9ca3e584bc7d5bb94f9555e9e17353242e6ec4505ff4880d

COPY --chmod=755 --from=builder /usr/bin/caddy /usr/bin/caddy
# Default healthcheck; private homelab compose overrides with tighter
# timing (15s/5s/5/30s) for VRRP failover detection.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD wget -q --spider http://127.0.0.1:80/health || exit 1
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
