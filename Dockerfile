# check=error=true
ARG CADDY_WORKDIR=/srv

FROM caddy:2.11-builder@sha256:8910fe662f448b860e8d16ef1c9a4f8946d3193bdc3e971bf0c55c9a2cf246f6 AS base
ENV GOTOOLCHAIN=auto

FROM base AS builder

COPY LICENSE NOTICE /src/
COPY licenses/ /src/licenses/
COPY scripts/collect-licenses.sh /usr/local/bin/collect-licenses.sh
# Raises x/net above the v0.59.0 the builder's Caddy v2.11.7 requires (CVE-2026-78669, -78663, -97032, -78660, -78659).
# The --with blank-imports http2, a package Caddy already links. Once the builder's Caddy requires this x/net or newer,
# delete the ARG and the --with: a newer requirement makes xcaddy's go get fail rather than downgrade Caddy.
# renovate: datasource=go depName=golang.org/x/net
ARG X_NET_VERSION=v0.61.0
# XCADDY_SKIP_CLEANUP keeps the generated build module so its dependency graph can be walked
# after the build: xcaddy builds outside any module of ours, and the license tree has to
# come from the module set that actually went into /usr/bin/caddy.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    XCADDY_SKIP_CLEANUP=1 xcaddy build \
        --with github.com/caddy-dns/cloudflare@v0.2.4 \
        --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.14.1 \
        --with "golang.org/x/net/http2@${X_NET_VERSION}" \
    && set -- /tmp/buildenv_* && [ "$#" -eq 1 ] && [ -d "$1" ] \
    && cp /src/LICENSE /src/NOTICE "$1"/ && cp -r /src/licenses "$1"/ \
    && sh /usr/local/bin/collect-licenses.sh --src "$1" --name docker-caddy . \
    && rm -rf "$1"

FROM builder AS test
COPY tests/ /tmp/tests/
COPY Caddyfile.example /tmp/tests/Caddyfile.example
COPY Caddyfile.plugins.example /tmp/tests/Caddyfile.plugins.example
COPY alerts/ /tmp/tests/alerts/
COPY compose.yaml /tmp/tests/compose.yaml
RUN sh /tmp/tests/smoke.sh

# Asserts the freshly built probe runs on this arch and exits 1 for an unreachable URL: non-zero is what the HEALTHCHECK below rests on, and 1 rather than the 2 Docker's contract reserves.
FROM base AS probe-builder
# renovate: datasource=go depName=github.com/cplieger/health/probe
ARG HEALTH_PROBE_VERSION=v1.1.0
COPY LICENSE NOTICE /src/
COPY scripts/collect-licenses.sh /usr/local/bin/collect-licenses.sh
WORKDIR /src
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOBIN=/out go install "github.com/cplieger/health/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && { out=$(/out/probe -timeout 1s http://127.0.0.1:9/ 2>&1); [ "$?" -eq 1 ] || { printf '%s\n' "probe unreachable-contract check failed (want exit 1), output:" "$out" >&2; exit 1; }; } \
    && go mod init docker-caddy >/dev/null 2>&1 \
    && GOFLAGS=-mod=mod go get "github.com/cplieger/health/probe/cmd/probe@${HEALTH_PROBE_VERSION}" \
    && sh /usr/local/bin/collect-licenses.sh --name docker-caddy github.com/cplieger/health/probe/cmd/probe

FROM caddy:2.11@sha256:3095ad245c353e3bdb27a38f22a095c1cfa9e295ab21c0214c3e72b0e2960525 AS donor

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

FROM gcr.io/distroless/static-debian13:latest@sha256:034df5c1737e8241f6ed6423a12e720ee0f6d6f088609ee172f98f6f2166ef5d

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
