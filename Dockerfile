# check=error=true
FROM caddy:2.11-builder@sha256:4bdeabce8e79d36b23d1cba7d20598cec2c1117ace960d8ca06071f945e8fc9b AS base
ENV GOTOOLCHAIN=auto

FROM base AS builder

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    xcaddy build \
        --with github.com/caddy-dns/cloudflare@v0.2.4 \
        --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.14.1

FROM builder AS test
COPY tests/ /tmp/tests/
COPY Caddyfile.example /tmp/tests/Caddyfile.example
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# The distroless runtime has no shell or wget, so the image ships cplieger/health's probe.
# The trailing checks assert its exit-code contract (2 usage, 1 unreachable) on this arch.
FROM base AS probe-builder
# renovate: datasource=go depName=github.com/cplieger/health/probe
ARG HEALTH_PROBE_VERSION=v1.0.3
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOBIN=/out go install "github.com/cplieger/health/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && { out=$(/out/probe 2>&1); [ "$?" -eq 2 ] || { printf '%s\n' "probe usage-contract check failed (want exit 2), output:" "$out" >&2; exit 1; }; } \
    && { out=$(/out/probe -timeout 1s http://127.0.0.1:9/ 2>&1); [ "$?" -eq 1 ] || { printf '%s\n' "probe unreachable-contract check failed (want exit 1), output:" "$out" >&2; exit 1; }; }

# The distroless final stage COPIES the runtime contract out of this digest-pinned
# upstream image, so Renovate keeps upstream contract changes flowing; only the
# ENV/EXPOSE/WORKDIR metadata below is hand-cloned (re-check it on a major Caddy bump).
FROM caddy:2.11@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d AS donor

# ca-certificates (outbound ACME/LAPI TLS), tzdata (the TZ env contract), /etc/passwd
# and /tmp ship in the base and Caddy is a static Go binary, so nothing is installed.
# Upstream's setcap'd binary loses its file capability on any COPY (xattrs are not
# carried); see the README's unprivileged recipe.
FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2

# XDG_DATA_HOME is what makes `/data` the certificate/ACME store — without it Caddy
# falls back to $HOME/.local/share/caddy and cert persistence across restarts breaks
# for every user of the documented /data volume.
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

# 2019 is Caddy's unauthenticated admin API: it stays loopback-bound by default
# (no CADDY_ADMIN env), so publishing it reaches a listener that answers only
# inside the container unless a Caddyfile deliberately rebinds admin off loopback.
EXPOSE 80 443 443/udp 2019
WORKDIR /srv

# Caddyfiles that set `admin off` or rebind admin must override this healthcheck;
# see the README for the end-to-end and dual-URL overrides. /probe's 4s budget is
# pinned strictly below Docker's 5s --timeout so a slow or hung admin API is reported
# by exit code and stderr instead of force-killed; benign reload lock-holds on GET
# /config/ are sub-second, so multi-second admin latency is the degraded state.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["/probe", "-timeout", "4s", "http://127.0.0.1:2019/config/"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
