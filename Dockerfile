# check=error=true
ARG CADDY_WORKDIR=/srv

FROM caddy:2.11-builder@sha256:b8f9c720f13f64c13dd42db28e8f38a3fab54c11fce4d93bda26d710c448dcfd AS base
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
COPY alerts/ /tmp/tests/alerts/
COPY compose.yaml /tmp/tests/compose.yaml
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# Asserts the freshly built probe runs on this arch and exits 1 for an unreachable URL: non-zero is what the HEALTHCHECK below rests on, and 1 rather than the 2 Docker's contract reserves.
FROM base AS probe-builder
# renovate: datasource=go depName=github.com/cplieger/health/probe
ARG HEALTH_PROBE_VERSION=v1.0.4
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOBIN=/out go install "github.com/cplieger/health/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && { out=$(/out/probe -timeout 1s http://127.0.0.1:9/ 2>&1); [ "$?" -eq 1 ] || { printf '%s\n' "probe unreachable-contract check failed (want exit 1), output:" "$out" >&2; exit 1; }; }

FROM caddy:2.11@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d AS donor

FROM donor AS donor-contract
ARG CADDY_WORKDIR
COPY --from=builder /usr/bin/caddy /custom-caddy
RUN set -eu; \
    custom=$(/custom-caddy version); custom=${custom%% *}; \
    donor=$(caddy version); donor=${donor%% *}; \
    [ "$custom" = "$donor" ] || { printf '%s\n' "custom binary is $custom but the runtime donor is $donor" "bump the lagging pin: the caddy:2.11-builder and caddy:2.11 pins are independent digests Renovate moves in separate PRs" >&2; exit 1; }; \
    [ "$(pwd)" = "$CADDY_WORKDIR" ] || { printf '%s\n' "donor WORKDIR is $(pwd); this Dockerfile declares $CADDY_WORKDIR" >&2; exit 1; }; \
    [ "${XDG_DATA_HOME:-}" = /data ] || { printf '%s\n' "donor XDG_DATA_HOME is ${XDG_DATA_HOME:-<unset>}; this Dockerfile clones /data" >&2; exit 1; }; \
    [ "${XDG_CONFIG_HOME:-}" = /config ] || { printf '%s\n' "donor XDG_CONFIG_HOME is ${XDG_CONFIG_HOME:-<unset>}; this Dockerfile clones /config" >&2; exit 1; }

FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2

COPY --from=donor /etc/caddy /etc/caddy
COPY --from=donor /usr/share/caddy /usr/share/caddy
COPY --from=donor /etc/mime.types /etc/mime.types
COPY --from=donor /config /config
COPY --from=donor /data /data
# Hand-cloned, not COPYed from the donor: XDG_DATA_HOME is what makes /data the cert store; donor-contract asserts both against the donor.
ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data

# From donor-contract, not builder: this COPY is the edge that forces the parity stage to run.
COPY --chmod=755 --from=donor-contract /custom-caddy /usr/bin/caddy
COPY --chmod=755 --from=probe-builder /out/probe /probe
# Force the test stage to build and pass before the runtime image is produced.
COPY --from=test /tests-passed /tests-passed

EXPOSE 80 443 443/udp 2019
ARG CADDY_WORKDIR
WORKDIR ${CADDY_WORKDIR}

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["/probe", "-timeout", "4s", "http://127.0.0.1:2019/config/"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
