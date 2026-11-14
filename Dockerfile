# check=error=true
ARG CADDY_WORKDIR=/srv

FROM caddy:2.11-builder@sha256:6350162b3889ca32600b3c699c61572fa0eb3ad6b2a51874f19b158a7df77511 AS base
ENV GOTOOLCHAIN=auto

FROM base AS builder

COPY LICENSE NOTICE /src/
COPY licenses/ /src/licenses/
COPY scripts/collect-licenses.sh /usr/local/bin/collect-licenses.sh
# Each ARG below raises a module above the version the builder's Caddy requires: x/net for CVE-2026-78669, -78663,
# -97032, -78660 and -78659, x/crypto for GO-2026-5932, and otel sdk/log for CVE-2026-128085 (it raises the otel sdk
# and trace modules with it). Each --with blank-imports a package Caddy already links. Once the builder's Caddy requires
# a module at its ARG's version or newer, delete that ARG and its --with: a newer requirement makes xcaddy's go get fail
# rather than downgrade Caddy.
# renovate: datasource=go depName=golang.org/x/net
ARG X_NET_VERSION=v0.62.0
# renovate: datasource=go depName=golang.org/x/crypto
ARG X_CRYPTO_VERSION=v0.59.0
# renovate: datasource=go depName=go.opentelemetry.io/otel/sdk/log
ARG OTEL_SDK_LOG_VERSION=v1.47.0
# XCADDY_SKIP_CLEANUP keeps the generated build module so its dependency graph can be walked
# after the build: xcaddy builds outside any module of ours, and the license tree has to
# come from the module set that actually went into /usr/bin/caddy.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    XCADDY_SKIP_CLEANUP=1 xcaddy build \
        --with github.com/caddy-dns/cloudflare@v0.2.4 \
        --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.15.0 \
        --with "golang.org/x/net/http2@${X_NET_VERSION}" \
        --with "golang.org/x/crypto/cryptobyte@${X_CRYPTO_VERSION}" \
        --with "go.opentelemetry.io/otel/sdk/log@${OTEL_SDK_LOG_VERSION}" \
    && set -- /tmp/buildenv_* && [ "$#" -eq 1 ] && [ -d "$1" ] \
    && cp /src/LICENSE /src/NOTICE "$1"/ && cp -r /src/licenses "$1"/ \
    && sh /usr/local/bin/collect-licenses.sh --src "$1" --name docker-caddy . \
    && rm -rf "$1"

FROM builder AS test
COPY tests/ /tmp/tests/
COPY Caddyfile.example /tmp/tests/Caddyfile.example
COPY Caddyfile.plugins.example /tmp/tests/Caddyfile.plugins.example
COPY alerts/ /tmp/tests/alerts/
COPY docs/monitoring.md /tmp/tests/docs/monitoring.md
COPY compose.yaml /tmp/tests/compose.yaml
COPY Dockerfile /tmp/tests/Dockerfile
RUN sh /tmp/tests/smoke.sh

# Asserts the freshly built probe runs on this arch and exits 1 for an unreachable URL: non-zero is what the HEALTHCHECK below rests on, and 1 rather than the 2 Docker's contract reserves.
FROM base AS probe-builder
# renovate: datasource=go depName=github.com/cplieger/go/health/v2
ARG HEALTH_PROBE_VERSION=v2.0.0
COPY LICENSE NOTICE /src/
COPY scripts/collect-licenses.sh /usr/local/bin/collect-licenses.sh
WORKDIR /src
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOBIN=/out go install "github.com/cplieger/go/health/v2/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && { out=$(/out/probe -timeout 1s http://127.0.0.1:9/ 2>&1); [ "$?" -eq 1 ] || { printf '%s\n' "probe unreachable-contract check failed (want exit 1), output:" "$out" >&2; exit 1; }; } \
    && go mod init docker-caddy >/dev/null 2>&1 \
    && GOFLAGS=-mod=mod go get "github.com/cplieger/go/health/v2/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && sh /usr/local/bin/collect-licenses.sh --name docker-caddy github.com/cplieger/go/health/v2/probe/cmd/probe

FROM caddy:2.11@sha256:4e2425f6009577e7c651010f16679c28f7d12df3e7b1914f941a7a3370746b3c AS donor

FROM donor AS donor-contract
ARG CADDY_WORKDIR
# From test, not builder: this COPY is the edge that forces the smoke test to run before parity is checked.
COPY --from=test /usr/bin/caddy /custom-caddy
RUN set -eu; \
    custom=$(/custom-caddy version); custom=${custom%% *}; \
    donor=$(caddy version); donor=${donor%% *}; \
    [ "$custom" = "$donor" ] || { printf '%s\n' "custom binary is $custom but the runtime donor is $donor" "bump the lagging pin: the caddy:2.11-builder and caddy:2.11 pins are independent digests Renovate moves in separate PRs" >&2; exit 1; }; \
    [ "$(pwd)" = "$CADDY_WORKDIR" ] || { printf '%s\n' "donor WORKDIR is $(pwd); this Dockerfile declares $CADDY_WORKDIR" >&2; exit 1; }; \
    [ "${XDG_DATA_HOME:-}" = /data ] || { printf '%s\n' "donor XDG_DATA_HOME is ${XDG_DATA_HOME:-<unset>}; this Dockerfile clones /data" >&2; exit 1; }; \
    [ "${XDG_CONFIG_HOME:-}" = /config ] || { printf '%s\n' "donor XDG_CONFIG_HOME is ${XDG_CONFIG_HOME:-<unset>}; this Dockerfile clones /config" >&2; exit 1; }

FROM gcr.io/distroless/static-debian13:latest@sha256:1a64f46364620465ef9e9a8f5413757dfdf22695e050bbfd7303eeaf17a59383

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
COPY --from=builder /out/usr/share/licenses /usr/share/licenses
COPY --from=probe-builder /out/usr/share/licenses /usr/share/licenses

EXPOSE 80 443 443/udp 2019
ARG CADDY_WORKDIR
WORKDIR ${CADDY_WORKDIR}

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["/probe", "-timeout", "4s", "http://127.0.0.1:2019/config/"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
