# docker-caddy

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-caddy/badges/size.json)](https://github.com/cplieger/docker-caddy/pkgs/container/docker-caddy)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![built from: caddy-builder](https://img.shields.io/badge/built%20from-caddy--builder-1F88C0?logo=caddy)
![runtime: distroless/static](https://img.shields.io/badge/runtime-distroless%2Fstatic-blue)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13203/badge)](https://www.bestpractices.dev/projects/13203)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-caddy/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-caddy)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-caddy/releases)

[Caddy](https://caddyserver.com/) reverse proxy and web server, custom-built with [`xcaddy`](https://github.com/caddyserver/xcaddy) to bundle the Cloudflare DNS-01 plugin and the CrowdSec HTTP bouncer.

## What it does

Caddy is a modern, automatic-HTTPS reverse proxy and web server. This image rebuilds it from upstream's official builder with two extra plugins so you can:

- **Issue ACME certificates via Cloudflare DNS-01** — for wildcard certs and internal-only services (see [Plugins](#plugins) for details).
- **Block IPs flagged by CrowdSec** — community-driven threat intel applied at the reverse-proxy layer, before requests reach your backends.

The binary is built with upstream's official builder and the runtime contract (config/data locations, default Caddyfile, welcome page, MIME map) is copied out of upstream's official image, so all of Caddy's [standard features](https://caddyserver.com/docs/) work as documented.

### Why this design

- **Built from the official builder** — uses Caddy builder so the binary matches upstream Caddy exactly. Plugins are compiled in with `xcaddy`, the upstream-prescribed mechanism.
- **Distroless runtime** — the final stage is `gcr.io/distroless/static`: no shell, no package manager, no OS packages to patch or scan. Caddy is a static Go binary, so the runtime needs nothing beyond the base's ca-certificates and tzdata (`TZ` is honored; the `xcaddy` build drops Go's embedded zoneinfo, so the base providing it matters). There is nothing to `docker exec` into — debug via logs, metrics, and the admin API.
- **Upstream contract preserved via a donor stage** — the default Caddyfile, welcome page, `/etc/mime.types` (Caddy's `file_server` consults it), the pre-created `/config` + `/data` state dirs, and the `XDG_*` env that makes `/data` the certificate store are copied from the digest-pinned upstream runtime image, not hand-cloned, so upstream contract changes keep flowing in via ordinary image bumps.
- **Plugins pinned to specific versions** — `caddy-dns/cloudflare` and `hslatman/caddy-crowdsec-bouncer` are tracked by Renovate and updated via dependency PRs.
- **Multi-arch, built natively** — CI builds each architecture on its own native runner (amd64 + arm64), so `xcaddy` compiles on matching hardware. No QEMU emulation and no buildx cross-compile build args.
- **Watch mode enabled by default** — `caddy run --watch` reloads the Caddyfile on change without restarting the container.

## Quick start

Available from both `ghcr.io/cplieger/docker-caddy` and `docker.io/cplieger/docker-caddy` — identical images and tags.

```yaml
services:
  caddy:
    image: ghcr.io/cplieger/docker-caddy:latest
    container_name: caddy
    restart: unless-stopped

    environment:
      # Provide these via a gitignored .env file (compose reads it automatically)
      # or a secrets manager — never commit live tokens into this file.
      CLOUDFLARE_API_TOKEN: "${CLOUDFLARE_API_TOKEN:?set in .env}"   # used by the DNS-01 plugin
      CROWDSEC_BOUNCER_KEY: "${CROWDSEC_BOUNCER_KEY:?set in .env}"   # used by the CrowdSec bouncer

    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"   # HTTP/3

    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
```

Create a gitignored `.env` next to `compose.yaml` with your real values (compose
loads it automatically):

```sh
cat > .env <<'EOF'
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token
CROWDSEC_BOUNCER_KEY=your-crowdsec-bouncer-key
EOF
```

A minimal Caddyfile that uses both plugins:

```caddy
{
    # Lock the admin API (config read/write) to loopback inside the container.
    admin localhost:2019

    crowdsec {
        api_url http://crowdsec:8080
        api_key {env.CROWDSEC_BOUNCER_KEY}
    }
}

*.example.com {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    crowdsec
    reverse_proxy backend:3000
}
```

The `admin localhost:2019` directive makes Caddy's loopback-only admin bind explicit (it is also Caddy's documented default) — the built-in healthcheck probes this address, and stating it guards against a global options block accidentally rebinding it. Do not set the `CADDY_ADMIN` env var on the compose service, as it overrides this directive.

## Configuration reference

### Environment variables

Caddy reads its full config from the Caddyfile; environment variables are only used inside the Caddyfile via `{env.VAR}` substitutions. Common ones:

| Variable               | Used by                  | Description                                                               |
| ---------------------- | ------------------------ | ------------------------------------------------------------------------- |
| `CLOUDFLARE_API_TOKEN` | `caddy-dns/cloudflare`   | API token with `Zone:Zone:Read` + `Zone:DNS:Edit` for the zones you serve |
| `CROWDSEC_BOUNCER_KEY` | `caddy-crowdsec-bouncer` | Bouncer API key (generate with `cscli bouncers add caddy`)                |

### Volumes

| Mount                  | Description                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `/etc/caddy/Caddyfile` | Your Caddyfile (read-only is fine; `--watch` watches for changes)                                                                     |
| `/data`                | Caddy's data directory — issued certificates, ACME state, plugin storage. **Persist this** or you'll re-issue certs on every restart. |
| `/config`              | (optional) Caddy's auto-generated JSON config and persistent state                                                                    |

### Ports

| Port  | Protocol | Purpose                                                   |
| ----- | -------- | --------------------------------------------------------- |
| `80`  | TCP      | HTTP — used for HTTP-01 challenges and redirects to HTTPS |
| `443` | TCP      | HTTPS / HTTP/2                                            |
| `443` | UDP      | HTTP/3 (QUIC)                                             |

### Running unprivileged

The image runs as **root** by default (the upstream Caddy default), so root binds ports 80 and 443 natively and the example needs no extra capability for them.

To run Caddy as a non-root user instead:

- set `user: "<uid>:<gid>"` on the service,
- `chown` the `/data` host directory to that UID (Caddy writes certs and ACME state there).

Under Docker's defaults that is all: containers start with `net.ipv4.ip_unprivileged_port_start=0`, so an unprivileged process binds 80/443 directly. `cap_add: [NET_BIND_SERVICE]` does **not** help a non-root user here — Docker grants added capabilities to root, and the binary carries no file capability (a `COPY` never preserves one, in this image and the previous Alpine-based one alike). If your daemon hardens `ip_unprivileged_port_start`, restore it per container with `sysctls: ["net.ipv4.ip_unprivileged_port_start=0"]` instead.

## Alerting

These alerts fire on Caddy's own built-in Prometheus metrics, so you have to turn metrics on first. Add the `metrics` global option to your Caddyfile and keep the admin API enabled (it is on by default):

```caddy
{
    metrics
}
```

Caddy then serves the metrics at the admin API's `/metrics` endpoint (`http://localhost:2019/metrics` with the example's `admin localhost:2019`). The admin API is bound to loopback, so scrape it from inside the container's network namespace (for example a monitoring sidecar) or expose it on a routable listener with Caddy's [`metrics`](https://caddyserver.com/docs/caddyfile/directives/metrics) handler directive.

The recommended rules live in [`alerts.yaml`](alerts.yaml); evaluate them with Prometheus or the Mimir ruler and route firing alerts through your Alertmanager. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `CaddyUpstreamUnhealthy` | a `reverse_proxy` upstream's health check reports it down for >5m | warning |
| `CaddyConfigReloadFailed` | the last config reload was rejected, so the running config is stale | critical |
| `CaddyHigh5xxRate` | more than 5% of responses are 5xx over 10m (at >1 req/s) | warning |

Thresholds and the `severity` labels are starting points; add your scrape `job` label to the selectors if you scrape more than one instance, and route by whatever labels your Alertmanager uses.

## Healthcheck

The image ships a **liveness** healthcheck (`30s interval / 6s Docker timeout / 3 retries / 15s start_period`; the probe enforces its own 5s budget — the 6s Docker ceiling gives it a margin to exit and report before Docker force-kills it): the bundled `/probe` binary ([`cplieger/health`](https://github.com/cplieger/health)'s `probe/cmd/probe`, the HTTP-probe module's standalone binary — the runtime has no shell or wget) GETs Caddy's admin API at `http://127.0.0.1:2019/config/`, which is enabled by default. This confirms Caddy is up, its config is loaded, and the admin plane is responsive (it catches faults like a hung reload that keep serving traffic while the admin API is dead), and it works out of the box for **any** Caddyfile — no route configuration required.

> **Note:** the default probe hits Caddy's admin API. If your Caddyfile sets `admin off` or rebinds the admin endpoint, this probe fails even though Caddy is serving normally — switch to the end-to-end `/health` override below in that case.

For an **end-to-end** check that verifies the proxy is actually serving traffic (listener bound, routing works), override the healthcheck to probe a `/health` route. The bundled [`Caddyfile.example`](./Caddyfile.example) serves one on plaintext `:80`:

```caddy
http://:80 {
    respond /health 200
}
```

It must live in an explicit `http://:80` block — Caddy auto-redirects `:80` → `:443` for HTTPS site blocks, so a `/health` route inside one would 308 rather than answer over plaintext. Then override in your compose:

```yaml
healthcheck:
  test: ["CMD", "/probe", "http://127.0.0.1:80/health"]
```

The probe accepts multiple URLs — every one must answer 2xx within a shared budget (`-timeout`, default 5s) — so you can watch the serving path **and** the admin plane in one healthcheck instead of choosing:

```yaml
healthcheck:
  test: ["CMD", "/probe", "http://127.0.0.1:80/health", "http://127.0.0.1:2019/config/"]
```

Exit codes: 0 healthy, 1 any probe failed (each failure is one stderr line naming the URL, visible in `docker inspect --format '{{json .State.Health}}'`), 2 usage error. Override the timing in your compose for tighter detection windows regardless of which probe you use.

## Plugins

### caddy-dns/cloudflare

Adds the `cloudflare` DNS provider to Caddy's `tls.dns` directive, enabling DNS-01 ACME challenges via the Cloudflare API. Useful for:

- **Wildcard certificates** (`*.example.com`) which only DNS-01 supports
- **Internal-only services** that aren't reachable from the public internet (so HTTP-01 / TLS-ALPN-01 can't work)

Source: [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)

### hslatman/caddy-crowdsec-bouncer

Adds a CrowdSec HTTP bouncer that checks every request against a locally cached copy of the active decision list (refreshed from the CrowdSec Local API via a streaming subscription) and blocks listed IPs — no network round-trip in the request path. CrowdSec scenarios (HTTP probes, scrapers, brute-force) trigger decisions that this bouncer enforces at the proxy layer.

> **Enforcement-only.** The bouncer pulls the active decision list from the CrowdSec LAPI (a lightweight cached stream) and blocks IPs. It does not run the CrowdSec engine, generate alerts, or touch the engine's database — so a healthy bouncer does not imply CrowdSec is detecting anything. The engine and its database (which, on SQLite, must run with `use_wal: true` or LAPI queries serialize and time out under bouncer-stream load) are a separate, server-side concern.

Source: [hslatman/caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer)

## Security

| Tool                                             | Result                                           |
| ------------------------------------------------ | ------------------------------------------------ |
| [hadolint](https://github.com/hadolint/hadolint) | Clean                                            |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected                              |
| [trivy](https://trivy.dev/)                      | Clean (distroless runtime: no OS packages)       |

Two transitive Go-module CVEs still surface in scans (`CVE-2026-44982` in CrowdSec, `CVE-2026-2303` in mongo-driver), but neither is reachable in this build: the bundled bouncer links only CrowdSec's LAPI client, so the vulnerable AppSec body parser and the MongoDB GSSAPI bindings are never compiled in. They clear once the upstream bouncer plugin supports CrowdSec 1.7.8+.

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-caddy:latest \
    --certificate-identity-regexp "https://github.com/cplieger/docker-caddy/.github/workflows/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency                  | Source                                                                   |
| --------------------------- | ------------------------------------------------------------------------ |
| caddy (builder)             | [Docker Hub](https://hub.docker.com/_/caddy)                             |
| caddy (contract donor)      | [Docker Hub](https://hub.docker.com/_/caddy)                             |
| distroless/static (runtime) | [gcr.io/distroless](https://github.com/GoogleContainerTools/distroless)  |
| caddy-dns/cloudflare        | [GitHub](https://github.com/caddy-dns/cloudflare)                        |
| caddy-crowdsec-bouncer      | [GitHub](https://github.com/hslatman/caddy-crowdsec-bouncer)             |
| health (probe binary)       | [GitHub](https://github.com/cplieger/health)                             |

## Credits

This project repackages [Caddy](https://caddyserver.com/) with two community plugins. All credit for the core functionality goes to the upstream maintainers:

- [Caddy](https://github.com/caddyserver/caddy) by [@mholt](https://github.com/mholt) and the Caddy community
- [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) — Cloudflare DNS-01 plugin
- [caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) by [@hslatman](https://github.com/hslatman) — CrowdSec bouncer
- [xcaddy](https://github.com/caddyserver/xcaddy) — Caddy plugin builder

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
