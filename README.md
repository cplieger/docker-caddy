# docker-caddy

[![CI](https://github.com/cplieger/docker-caddy/actions/workflows/ci.yaml/badge.svg)](https://github.com/cplieger/docker-caddy/actions/workflows/ci.yaml)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-caddy)](https://github.com/cplieger/docker-caddy/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-caddy/size)](https://github.com/cplieger/docker-caddy/pkgs/container/docker-caddy)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Caddy](https://img.shields.io/badge/base-Caddy-1F88C0?logo=caddy)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-caddy/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-caddy)

[Caddy](https://caddyserver.com/) reverse proxy and web server, custom-built with [`xcaddy`](https://github.com/caddyserver/xcaddy) to bundle the Cloudflare DNS-01 plugin and the CrowdSec HTTP bouncer.

## What it does

Caddy is a modern, automatic-HTTPS reverse proxy and web server. This image rebuilds it from upstream's official builder with two extra plugins so you can:

- **Issue ACME certificates via Cloudflare DNS-01** — for wildcard certs (e.g. `*.example.com`) and for internal-only services that aren't reachable from the public internet (no HTTP-01 / TLS-ALPN-01 ports needed).
- **Block IPs flagged by CrowdSec** — community-driven threat intel applied at the reverse-proxy layer, before requests reach your backends.

The base is upstream's official Caddy image, so all of Caddy's standard features work as documented (HTTP/3, on-demand TLS, automatic HTTPS, file server, FastCGI/php-fpm, WebSocket proxying, etc.).

### Why this design

- **Built from the official builder** — uses Caddy builder so the binary, ld-paths, and runtime layout match upstream Caddy exactly. No drift from the official image.
- **Plugins pinned to specific versions** — `caddy-dns/cloudflare` and `hslatman/caddy-crowdsec-bouncer` are tracked by Renovate and updated via dependency PRs.
- **Multi-arch native cross-compilation** — `xcaddy build GOOS=$TARGETOS GOARCH=$TARGETARCH` produces native amd64 and arm64 binaries; no QEMU needed.
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
      CLOUDFLARE_API_TOKEN: "your-cloudflare-api-token"   # used by the DNS-01 plugin
      CROWDSEC_BOUNCER_KEY: "your-crowdsec-bouncer-key"   # used by the CrowdSec bouncer

    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"   # HTTP/3
    cap_add:
      - NET_BIND_SERVICE

    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data

volumes:
  caddy_data:
```

A minimal Caddyfile that uses both plugins:

```caddy
{
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

## Configuration reference

### Environment variables

Caddy reads its full config from the Caddyfile; environment variables are only used inside the Caddyfile via `{env.VAR}` substitutions. Common ones:

| Variable | Used by | Description |
|----------|---------|-------------|
| `CLOUDFLARE_API_TOKEN` | `caddy-dns/cloudflare` | API token with `Zone:Zone:Read` + `Zone:DNS:Edit` for the zones you serve |
| `CROWDSEC_BOUNCER_KEY` | `caddy-crowdsec-bouncer` | Bouncer API key (generate with `cscli bouncers add caddy`) |

### Volumes

| Mount | Description |
|-------|-------------|
| `/etc/caddy/Caddyfile` | Your Caddyfile (read-only is fine; `--watch` watches for changes) |
| `/data` | Caddy's data directory — issued certificates, ACME state, plugin storage. **Persist this** or you'll re-issue certs on every restart. |
| `/config` | (optional) Caddy's auto-generated JSON config and persistent state |

### Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `80` | TCP | HTTP — used for HTTP-01 challenges and redirects to HTTPS |
| `443` | TCP | HTTPS / HTTP/2 |
| `443` | UDP | HTTP/3 (QUIC) |

## Healthcheck

The built-in healthcheck hits `http://127.0.0.1:80/health` with BusyBox `wget`. The image bundles a default healthcheck (`30s/5s/3 retries/15s start_period`); override the timing in your compose if you want tighter detection windows.

You'll need a matching `respond /health 200` line in your Caddyfile (or a route that returns 200 at `/health`):

```caddy
:80 {
    respond /health 200
}
```

## Plugins

### caddy-dns/cloudflare

Adds the `cloudflare` DNS provider to Caddy's `tls.dns` directive, enabling DNS-01 ACME challenges via the Cloudflare API. Useful for:

- **Wildcard certificates** (`*.example.com`) which only DNS-01 supports
- **Internal-only services** that aren't reachable from the public internet (so HTTP-01 / TLS-ALPN-01 can't work)

Source: [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)

### hslatman/caddy-crowdsec-bouncer

Adds a CrowdSec HTTP bouncer that queries the CrowdSec Local API on every request and blocks IPs in the active decision list. CrowdSec scenarios (HTTP probes, scrapers, brute-force) trigger decisions that this bouncer enforces at the proxy layer.

> **Enforcement-only.** The bouncer pulls the active decision list from the CrowdSec LAPI (a lightweight cached stream) and blocks IPs. It does not run the CrowdSec engine, generate alerts, or touch the engine's database — so a healthy bouncer does not imply CrowdSec is detecting anything. The engine and its database (which, on SQLite, must run with `use_wal: true` or LAPI queries serialize and time out under bouncer-stream load) are a separate, server-side concern.

Source: [hslatman/caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer)

## Security

| Tool | Result |
|------|--------|
| [hadolint](https://github.com/hadolint/hadolint) | Clean |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected |
| [trivy](https://trivy.dev/) | Inherits Caddy base image scan |

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-caddy:latest \
    --certificate-identity-regexp "https://github.com/cplieger/docker-caddy/.github/workflows/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Source |
|------------|--------|
| caddy (builder) | [Docker Hub](https://hub.docker.com/_/caddy) |
| caddy (runtime) | [Docker Hub](https://hub.docker.com/_/caddy) |
| caddy-dns/cloudflare | [GitHub](https://github.com/caddy-dns/cloudflare) |
| caddy-crowdsec-bouncer | [GitHub](https://github.com/hslatman/caddy-crowdsec-bouncer) |

## Credits

This project repackages [Caddy](https://caddyserver.com/) with two community plugins. All credit for the core functionality goes to the upstream maintainers:

- [Caddy](https://github.com/caddyserver/caddy) by [@mholt](https://github.com/mholt) and the Caddy community
- [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) — Cloudflare DNS-01 plugin
- [caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) by [@hslatman](https://github.com/hslatman) — CrowdSec bouncer
- [xcaddy](https://github.com/caddyserver/xcaddy) — Caddy plugin builder

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This image is built with care and follows security best practices, but it is intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
