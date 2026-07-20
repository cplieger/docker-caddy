# check=error=true
FROM caddy:2.11-builder@sha256:198d47eaee306d4d0c38a9960c89ff2c959aa29ad51d3e2dafa3e93ac961782a AS base
ENV GOTOOLCHAIN=auto

FROM base AS builder

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

# ---------------------------------------------------------------------------
# Probe stage — builds the static healthcheck binary. The distroless runtime
# has no shell or wget, so the image ships the HTTP probe module of
# github.com/cplieger/health (probe/cmd/probe, its own release lane) as its
# HEALTHCHECK tool. The trailing checks assert the freshly built probe runs
# on this arch and honors its exit-code contract (2 usage, 1 unreachable)
# before it ships as the image's only healthcheck path.
# ---------------------------------------------------------------------------
FROM base AS probe-builder
# renovate: datasource=go depName=github.com/cplieger/health/probe
ARG HEALTH_PROBE_VERSION=v1.0.0
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOBIN=/out go install "github.com/cplieger/health/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && { /out/probe >/dev/null 2>&1; [ "$?" -eq 2 ]; } \
    && { /out/probe -timeout 1s http://127.0.0.1:9/ >/dev/null 2>&1; [ "$?" -eq 1 ]; }

# ---------------------------------------------------------------------------
# Contract donor — the upstream runtime image this image previously shipped
# on. The distroless final stage cannot run upstream's setup commands, so it
# COPIES the runtime contract out of the digest-pinned upstream image instead
# of hand-cloning it: the default Caddyfile, the welcome page, the mime.types
# map Caddy's file_server consults, and the pre-created state dirs with their
# 1777 modes. Renovate keeps bumping this digest, so upstream contract changes
# keep flowing into the final image automatically — only the ENV/EXPOSE/
# WORKDIR metadata below is hand-cloned (re-check it on a major Caddy bump).
# ---------------------------------------------------------------------------
FROM caddy:2.11@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9 AS donor

# ---------------------------------------------------------------------------
# Runtime — distroless/static: no shell, no package manager, no OS packages
# to patch or scan. ca-certificates (outbound ACME/LAPI TLS), tzdata (the TZ
# env contract), /etc/passwd (root), and /tmp ship in the base. Caddy is a
# static Go binary, so nothing else is needed at runtime.
#
# Root stays the image default so the documented out-of-the-box low-port
# behavior is unchanged. Note upstream's setcap'd binary loses its file
# capability on any COPY (xattrs are not carried), in this image and in the
# previous Alpine-based one alike — non-root low-port binding rides Docker's
# default `net.ipv4.ip_unprivileged_port_start=0` instead; see the README's
# unprivileged recipe.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:latest@sha256:61b7ccecebc7c474a531717de80a94709d20547cdcdaf740c25876f2a8e38b44

# Upstream runtime contract (see the donor stage comment). XDG_DATA_HOME is
# what makes `/data` the certificate/ACME store — without it Caddy would
# silently fall back to $HOME/.local/share/caddy and cert persistence across
# restarts would break for every user of the documented /data volume.
COPY --from=donor /etc/caddy /etc/caddy
COPY --from=donor /usr/share/caddy /usr/share/caddy
COPY --from=donor /etc/mime.types /etc/mime.types
COPY --from=donor /config /config
COPY --from=donor /data /data
ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data

COPY --chmod=755 --from=builder /usr/bin/caddy /usr/bin/caddy
COPY --chmod=755 --from=probe-builder /out/probe /probe
# Force the test stage to build and pass before the runtime image is produced.
COPY --from=test /tests-passed /tests-passed

# Deliberate divergence from upstream's EXPOSE metadata: the unauthenticated
# admin API (2019) stays loopback-only (no CADDY_ADMIN env) and is NOT
# advertised, so `docker run -P` cannot invite publishing the admin plane.
EXPOSE 80 443 443/udp
WORKDIR /srv

# Liveness probe against Caddy's admin API on 127.0.0.1:2019: route-independent
# while the admin API stays enabled at its default loopback address, and it
# catches admin-plane faults (hung reloads) that a serving-route probe misses.
# Caddyfiles that set `admin off` or rebind admin must override the healthcheck
# to a route-level probe. For an end-to-end check that the proxy actually
# serves traffic, override in compose to probe a /health route — or probe BOTH
# surfaces in one run: ["/probe", "http://127.0.0.1:80/health",
# "http://127.0.0.1:2019/config/"]. See Caddyfile.example and the README.
# Docker's --timeout (6s) sits one second above /probe's explicit 5s failure
# budget (-timeout below, pinned so a probe-release default change cannot
# silently invert the relationship) so a slow or hung admin API is reported
# by the probe's exit code and stderr diagnostic instead of being force-killed
# mid-report.
HEALTHCHECK --interval=30s --timeout=6s --retries=3 --start-period=15s \
    CMD ["/probe", "-timeout", "5s", "http://127.0.0.1:2019/config/"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
