# check=error=true
FROM caddy:2.11-builder@sha256:e04bd0aadab74d4ff446980f956fe3c63be24678f1838906962b56a7cab2d028 AS base
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
COPY Caddyfile.plugins.example /tmp/tests/Caddyfile.plugins.example
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# Asserts /probe's exit-code contract (2 usage, 1 unreachable): the HEALTHCHECK below reads those codes and HEALTH_PROBE_VERSION is Renovate-bumped.
FROM base AS probe-builder
# renovate: datasource=go depName=github.com/cplieger/health/probe
ARG HEALTH_PROBE_VERSION=v1.0.4
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOBIN=/out go install "github.com/cplieger/health/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && { out=$(/out/probe 2>&1); [ "$?" -eq 2 ] || { printf '%s\n' "probe usage-contract check failed (want exit 2), output:" "$out" >&2; exit 1; }; } \
    && { out=$(/out/probe -timeout 1s http://127.0.0.1:9/ 2>&1); [ "$?" -eq 1 ] || { printf '%s\n' "probe unreachable-contract check failed (want exit 1), output:" "$out" >&2; exit 1; }; }

FROM caddy:2.11@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d AS donor

FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2

COPY --from=donor /etc/caddy /etc/caddy
COPY --from=donor /usr/share/caddy /usr/share/caddy
COPY --from=donor /etc/mime.types /etc/mime.types
COPY --from=donor /config /config
COPY --from=donor /data /data
# Hand-cloned, not COPYed from the donor: XDG_DATA_HOME is what makes /data the cert store — re-check on a major Caddy bump.
ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data

COPY --chmod=755 --from=builder /usr/bin/caddy /usr/bin/caddy
COPY --chmod=755 --from=probe-builder /out/probe /probe
# Force the test stage to build and pass before the runtime image is produced.
COPY --from=test /tests-passed /tests-passed

EXPOSE 80 443 443/udp 2019
WORKDIR /srv

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["/probe", "-timeout", "4s", "http://127.0.0.1:2019/config/"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
