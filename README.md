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

- **Issue ACME certificates via Cloudflare DNS-01**: for wildcard certs and internal-only services (see [Plugins](#plugins) for details).
- **Block IPs flagged by CrowdSec**: community-driven threat intel applied at the reverse-proxy layer, before requests reach your backends.

All of Caddy's [standard features](https://caddyserver.com/docs/) work as documented.

### Why this design

- **Built from the official builder.** The binary matches upstream Caddy exactly; plugins are compiled in with `xcaddy`, the upstream-prescribed mechanism.
- **Distroless runtime.** The final stage is `gcr.io/distroless/static`: no shell, no package manager, no OS packages to patch or scan. `TZ` is honored (the base ships tzdata). There is no shell to `docker exec` into, and `docker exec` can only run the shipped binaries (`caddy`, `/probe`); debugging is otherwise via logs, metrics, and the admin API.
- **Upstream contract preserved.** The default Caddyfile, welcome page, MIME map, state directories, and the `XDG_*` env that makes `/data` the certificate store are copied from the upstream runtime image, so upstream contract changes keep flowing in with ordinary image updates.
- **Multi-arch, built natively.** amd64 and arm64 each compile on matching hardware, with no emulation.
- **Config reload without a restart.** Send the running process SIGUSR1
  (`docker kill -s USR1 caddy`) and Caddy reloads from the `--config` file and
  `--adapter` this image's CMD already records. For a deploy script that needs a
  rejected Caddyfile on the caller's own exit status, use
  `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`.
  Either way a rejected Caddyfile leaves the previous config running.
- **Watch mode available, off by default.** Upstream documents `--watch` as a
  local-development feature, so the shipped command is upstream's. To opt in, override
  the command on your compose service:

  ```yaml
  command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
  ```

  Know what that turns on: one save that fails to ADAPT stops the watcher for the
  lifetime of the container, and later valid edits are then ignored with no healthcheck
  and no metric reporting it; the `watcher` logger emits `unable to load latest config`
  once, carrying the adapter error, at the moment it dies. Recovery is a container
  restart; an explicit reload applies the current file but does not revive the watcher.
  Validate before saving with
  `docker exec caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile`.
  Separately, a single-file bind mount pins an inode, so an editor that saves by rename
  leaves the container reading the old bytes; save in place, or mount the directory
  (`./caddy:/etc/caddy`). That defeats every reload path, not only the watcher.

## Quick start

Available from both `ghcr.io/cplieger/docker-caddy` and `docker.io/cplieger/docker-caddy`: identical images and tags.

```yaml
services:
  caddy:
    image: ghcr.io/cplieger/docker-caddy:latest
    container_name: caddy
    restart: unless-stopped

    environment:
      TZ: "Europe/Paris"
      # Set these in a gitignored .env file; never commit live tokens.
      CLOUDFLARE_API_TOKEN: "${CLOUDFLARE_API_TOKEN:-}"   # used by the DNS-01 plugin
      CROWDSEC_BOUNCER_KEY: "${CROWDSEC_BOUNCER_KEY:-}"   # used by the CrowdSec bouncer

    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"   # HTTP/3

    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
```

The bundled [`Caddyfile.plugins.example`](./Caddyfile.plugins.example) is a minimal Caddyfile that uses both plugins; copy it to `Caddyfile` and make three edits: the site address, the `reverse_proxy` target, and `crowdsec.api_url` — a CrowdSec LAPI address reachable from the Caddy container. The shipped `http://crowdsec:8080` assumes a `crowdsec` service alias on a shared Compose network, which the one-service compose example above does not create; the bouncer fails open on a LAPI it cannot reach, so a wrong value serves every request unblocked. It reads `CLOUDFLARE_API_TOKEN` for the DNS-01 challenge and `CROWDSEC_BOUNCER_KEY` for the bouncer, both of which the compose service above passes through. The build's smoke test validates that file against the shipped binary, so the example cannot drift from what the image can load.

Both shipped examples state `admin localhost:2019`, which makes Caddy's loopback-only admin bind explicit (it is also Caddy's documented default). The built-in healthcheck probes this address; stating it guards against a global options block accidentally rebinding it. The directive outranks the `CADDY_ADMIN` env var, which only supplies the default admin address Caddy uses when no `admin` directive configures one.

## Configuration reference

### Environment variables

Caddy reads its full config from the Caddyfile; environment variables are only used inside the Caddyfile via `{env.VAR}` substitutions. Common ones:

| Variable | Description | Default |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | API token with `Zone:Zone:Read` + `Zone:DNS:Edit` for the zones you serve; read by the `caddy-dns/cloudflare` DNS-01 plugin via `{env.CLOUDFLARE_API_TOKEN}`. A token the plugin rejects on format is echoed verbatim into the container log, so treat any value that appears in a startup or reload error as exposed and rotate it. | _(unset)_ |
| `CROWDSEC_BOUNCER_KEY` | Bouncer API key (generate with `cscli bouncers add caddy`); read by the `caddy-crowdsec-bouncer` plugin via `{env.CROWDSEC_BOUNCER_KEY}`. | _(unset)_ |

Reference either credential only as `{env.VAR}`, never as a literal in the Caddyfile. The plugins resolve the placeholder at provision time, so the config the admin API serves at `GET /config/` keeps the placeholder; a hardcoded value comes back verbatim to anything that can reach that endpoint.

### Volumes

| Mount | Description |
| --- | --- |
| `/etc/caddy/Caddyfile` | Your Caddyfile (read-only is fine; reload with `docker kill -s USR1 caddy`, or `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`) |
| `/data` | Caddy's data directory: issued certificates, ACME state, plugin storage. **Persist this** or you'll re-issue certs on every restart. |
| `/config` | (optional) Caddy's auto-generated JSON config and persistent state |

### Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| `80` | TCP | HTTP: HTTP-01 challenges and redirects to HTTPS |
| `443` | TCP | HTTPS / HTTP/2 |
| `443` | UDP | HTTP/3 (QUIC) |
| `2019` | TCP | Caddy's admin API (unauthenticated): loopback-bound by default, so publishing it reaches a listener that answers only inside the container |

The admin API port is declared for documentation and for in-namespace scrapers; publishing it is only useful if a Caddyfile deliberately rebinds `admin` off loopback, and at that point it is an unauthenticated control plane on a routable address.

### Running unprivileged

The image runs as **root** by default (the upstream Caddy default), so root binds ports 80 and 443 natively and the example needs no extra capability for them.

To run Caddy as a non-root user instead:

- set `user: "<uid>:<gid>"` on the service,
- `chown` the `/data` host directory to that UID (Caddy writes certs and ACME state there).

Under Docker's defaults that is all: containers start with `net.ipv4.ip_unprivileged_port_start=0`, so an unprivileged process binds 80/443 directly. `cap_add: [NET_BIND_SERVICE]` does **not** help a non-root user here: Docker grants added capabilities to root, and the binary carries no file capability. If your daemon hardens `ip_unprivileged_port_start`, restore it per container with `sysctls: ["net.ipv4.ip_unprivileged_port_start=0"]` instead.

## Alerting

These alerts fire on metrics served by the admin API's `/metrics` endpoint, so keep the admin API enabled (it is on by default) and scrape it. `CaddyHigh5xxRate` additionally needs the `metrics` global option, which is what registers Caddy's per-request HTTP instrumentation:

```caddy
{
    metrics
}
```

With that set, the per-request series appear alongside the rest at `http://localhost:2019/metrics` (the example's `admin localhost:2019`). The admin API is bound to loopback, so scrape it from inside the container's network namespace (for example a monitoring sidecar) or expose it on a routable listener with Caddy's [`metrics`](https://caddyserver.com/docs/caddyfile/directives/metrics) handler directive.

The recommended rules live in [`alerts.yaml`](alerts.yaml), where each rule's own prerequisites are stated in the file's header; evaluate them with Prometheus or the Mimir ruler and route firing alerts through your Alertmanager. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `CaddyUpstreamUnhealthy` | a `reverse_proxy` upstream's health check reports it down for >5m | warning |
| `CaddyConfigReloadFailed` | the last config reload was rejected, so the running config is stale | critical |
| `CaddyHigh5xxRate` | more than 5% of responses are 5xx over 10m (at >1 req/s) | warning |
| `CrowdSecBouncerLAPIFailing` | more than half the bouncer's LAPI decision-stream polls have failed over 10m, so enforcement is fail-open | warning |

Thresholds and the `severity` labels are starting points; add your scrape `job` label to the selectors if you scrape more than one instance, and route by whatever labels your Alertmanager uses.

The bundle covers Caddy's own metrics and, with `enable_caddy_metrics` in the `crowdsec` global block (the shipped `Caddyfile.plugins.example` sets it), the bouncer's LAPI stream. It cannot cover certificate renewal: Caddy registers no certificate or ACME series, so a DNS-01 renewal that stops working is detectable only from outside, with a TLS prober against the served site.

## Healthcheck

The image ships a **liveness** healthcheck: the bundled `/probe` binary (from [`cplieger/health`](https://github.com/cplieger/health); the runtime has no shell or wget) GETs Caddy's admin API at `http://127.0.0.1:2019/config/`, which is enabled by default. This confirms Caddy is up, its config is loaded, and the admin plane is responsive (it catches faults like a hung reload that keep serving traffic while the admin API is dead). It works out of the box for **any** Caddyfile; no route configuration required.

> **Note:** the default probe hits Caddy's admin API. If your Caddyfile sets `admin off` or rebinds the admin endpoint, this probe fails even though Caddy is serving normally; switch to the end-to-end `/health` override below in that case.

For an **end-to-end** check that verifies the proxy is actually serving traffic (listener bound, routing works), override the healthcheck to probe a `/health` route. The bundled [`Caddyfile.example`](./Caddyfile.example) serves one on plaintext `:80`:

```caddy
http://:80 {
    respond /health 200
}
```

It must live in an explicit `http://:80` block: Caddy auto-redirects `:80` to `:443` for HTTPS site blocks, so a `/health` route inside one would 308 rather than answer over plaintext. Then override in your compose:

```yaml
healthcheck:
  test: ["CMD", "/probe", "-timeout", "4s", "http://127.0.0.1:80/health"]
```

The probe accepts multiple URLs; every one must answer 2xx within the shared `-timeout` budget. Pin `-timeout` to 4s as shown so it stays below Docker's 5s healthcheck timeout and a slow endpoint is reported instead of force-killed. This lets one healthcheck watch the serving path **and** the admin plane:

```yaml
healthcheck:
  test: ["CMD", "/probe", "-timeout", "4s", "http://127.0.0.1:80/health", "http://127.0.0.1:2019/config/"]
```

Exit codes: 0 healthy, 1 any probe failed (each failure is one stderr line naming the URL, visible in `docker inspect --format '{{json .State.Health}}'`), 2 usage error. Override the timing in your compose for tighter detection windows regardless of which probe you use.

## Plugins

### caddy-dns/cloudflare

Adds the `cloudflare` DNS provider to Caddy's `tls.dns` directive, enabling DNS-01 ACME challenges via the Cloudflare API. Useful for:

- **Wildcard certificates** (`*.example.com`) which only DNS-01 supports
- **Internal-only services** that aren't reachable from the public internet (so HTTP-01 / TLS-ALPN-01 can't work)

Source: [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)

### hslatman/caddy-crowdsec-bouncer

Adds a CrowdSec HTTP bouncer that checks every request against a locally cached copy of the active decision list (refreshed from the CrowdSec Local API via a streaming subscription) and blocks listed IPs, with no network round-trip in the request path. CrowdSec scenarios (HTTP probes, scrapers, brute-force) trigger decisions that this bouncer enforces at the proxy layer.

> **Enforcement-only.** The bouncer pulls the active decision list from the CrowdSec LAPI and blocks IPs. It does not run the CrowdSec engine, generate alerts, or touch the engine's database, so a healthy bouncer does not imply CrowdSec is detecting anything. The engine and its database are a separate, server-side concern; a SQLite-backed engine must run with `use_wal: true`, or LAPI queries serialize and time out under the bouncer's stream load.
>
> **Fail-open by default, and its failure is silent.** If the LAPI is unreachable the bouncer serves requests unblocked rather than refusing them, so a CrowdSec outage removes the protection without failing a single request, without a healthcheck transition, and, unless `enable_caddy_metrics` is set in the `crowdsec` global block, without a metric to alert on; the shipped `Caddyfile.plugins.example` sets it, and `alerts.yaml`'s `CrowdSecBouncerLAPIFailing` alerts on the failing LAPI poll. Set `enable_hard_fails` in the `crowdsec` global block to fail requests instead; the tradeoff is that a CrowdSec outage then becomes an outage of everything behind the proxy, which is why the default is the other way. The bouncer's own view is available at the admin API, `curl -XPOST http://127.0.0.1:2019/crowdsec/health`, which answers `{"Ok":false}` on a LAPI outage (the capital is the plugin's own JSON shape across all of its admin endpoints, so match on it exactly). Treat that as a manual or sidecar diagnostic: it answers only POST (a GET is 405'd, so the bundled `/probe` cannot be pointed at it) and it reports the outage in the body while returning HTTP 200, so a status-only prober reads it as success. The bundled rule detects the LAPI outage that causes the fail-open. Detecting the fail-open VERDICT itself still needs a body-aware POST prober — a `blackbox_exporter` module with `method: POST` and a body matcher, alerting on that probe's `probe_success` — which this image does not ship.

Source: [hslatman/caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer)

## Security

The runtime is distroless: no shell, no package manager, no OS packages to scan. Two transitive Go-module CVEs still surface in scans (`CVE-2026-44982` in CrowdSec, `CVE-2026-2303` in mongo-driver), but neither is reachable in this build: the bundled bouncer links only CrowdSec's LAPI client, so the vulnerable AppSec body parser and the MongoDB GSSAPI bindings are never compiled in. They clear once the upstream bouncer plugin supports CrowdSec 1.7.8+.

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

- [Caddy](https://github.com/caddyserver/caddy) by [@mholt](https://github.com/mholt) and the Caddy community (Apache-2.0)
- [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare): Cloudflare DNS-01 plugin (Apache-2.0)
- [caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) by [@hslatman](https://github.com/hslatman): CrowdSec bouncer (Apache-2.0)
- [xcaddy](https://github.com/caddyserver/xcaddy): Caddy plugin builder

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).
