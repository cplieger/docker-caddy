# docker-caddy

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-caddy/badges/size.json)](https://github.com/cplieger/docker-caddy/pkgs/container/docker-caddy)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![built from: caddy-builder](https://img.shields.io/badge/built%20from-caddy--builder-1F88C0?logo=caddy)
![runtime: distroless/static](https://img.shields.io/badge/runtime-distroless%2Fstatic-blue)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13203/badge)](https://www.bestpractices.dev/projects/13203)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-caddy/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-caddy)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-caddy/releases)

<!-- hub-overview BEGIN -->
[Caddy](https://caddyserver.com/) reverse proxy and web server, custom-built with [`xcaddy`](https://github.com/caddyserver/xcaddy) to bundle the Cloudflare DNS-01 plugin and the CrowdSec HTTP bouncer.

## What it does

Caddy is a modern, automatic-HTTPS reverse proxy and web server. This image rebuilds it from upstream's official builder with two extra plugins so you can:

- **Issue ACME certificates via Cloudflare DNS-01**: for wildcard certs and internal-only services (see [Plugins](#plugins) for details).
- **Block IPs flagged by CrowdSec**: community-driven threat intel applied at the reverse-proxy layer, before requests reach your backends.

All of Caddy's [standard features](https://caddyserver.com/docs/) work as documented.

### Why this design

- **Built from the official builder.** The binary matches upstream Caddy exactly; plugins are compiled in with `xcaddy`, the upstream-prescribed mechanism.
- **Distroless runtime.** The final stage is `gcr.io/distroless/static`: no shell, no package manager, no OS packages to patch or scan. `TZ` is honored (the base ships tzdata). There is no shell to `docker exec` into, and `docker exec` can only run the shipped binaries (`caddy`, `/probe`); debugging is otherwise via logs, metrics, and the admin API.
- **Upstream contract preserved.** The default Caddyfile, welcome page, MIME map and state directories are copied from the upstream runtime image, so upstream changes to them keep flowing in with ordinary image updates. The `XDG_*` env that makes `/data` the certificate store is declared by hand, because `COPY` moves files and not image ENV metadata, so it is re-checked on a major Caddy bump.
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
<!-- hub-overview END -->

## Quick start

Available from both `ghcr.io/cplieger/docker-caddy` and `docker.io/cplieger/docker-caddy`: identical images and tags.

```yaml
services:
  caddy:
    image: ghcr.io/cplieger/docker-caddy:latest
    container_name: caddy
    restart: unless-stopped

    environment:
      # Set these in a gitignored .env file; never commit live tokens.
      CLOUDFLARE_API_TOKEN: "${CLOUDFLARE_API_TOKEN:-}"   # used by the DNS-01 plugin
      CROWDSEC_BOUNCER_KEY: "${CROWDSEC_BOUNCER_KEY:-}"   # used by the CrowdSec bouncer

    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"   # HTTP/3

    volumes:
      - ./caddy:/etc/caddy:ro
      - ./data:/data
```

The bundled [`Caddyfile.plugins.example`](./Caddyfile.plugins.example) is a minimal Caddyfile that uses both plugins; copy it to `caddy/Caddyfile` (`mkdir -p caddy && cp Caddyfile.plugins.example caddy/Caddyfile`) and make three edits: the site address, the `reverse_proxy` target, and `crowdsec.api_url`, a CrowdSec LAPI address reachable from the Caddy container. The shipped `http://crowdsec:8080` assumes a `crowdsec` service alias on a shared Compose network, which the one-service compose example above does not create; the bouncer fails open on a LAPI it cannot reach, so a wrong value serves every request unblocked. It reads `CLOUDFLARE_API_TOKEN` for the DNS-01 challenge and `CROWDSEC_BOUNCER_KEY` for the bouncer, both of which the compose service above passes through. Set both before the first start. The compose example defaults them to empty (`${VAR:-}`) rather than refusing to start. Each plugin refuses to provision on an empty credential, so Caddy exits at startup and the restart policy retries it. The build's smoke test validates that file against the shipped binary, so the example cannot drift from what the image can load.

Both shipped examples state `admin localhost:2019`, which makes Caddy's loopback-only admin bind explicit (it is also Caddy's documented default). The built-in healthcheck probes this address; stating it guards against a global options block accidentally rebinding it. The directive outranks the `CADDY_ADMIN` env var, which only supplies the default admin address Caddy uses when no `admin` directive configures one.

## Configuration reference

### Environment variables

Caddy reads its full config from the Caddyfile; environment variables are only used inside the Caddyfile via `{env.VAR}` substitutions. Common ones:

| Variable | Description | Default |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | API token with `Zone:Zone:Read` + `Zone:DNS:Edit` for the zones you serve; read by the `caddy-dns/cloudflare` DNS-01 plugin via `{env.CLOUDFLARE_API_TOKEN}`. A token the plugin rejects on format is echoed verbatim into the container log, so treat any value that appears in a startup or reload error as exposed and rotate it. The plugin's format check is anchored, so any extra character around the token fails it: surrounding quotes or braces, but also a stray space or a trailing newline picked up from a file. The error prints the whole value, so a good token can leak because of what surrounds it rather than what it is. Pass the bare token, with nothing around it. The check also accepts Cloudflare's API token formats only, so a different KIND of Cloudflare credential is rejected for what it is and printed the same way: a new-format Global API Key (`cfk_...`) and an Origin CA key (`v1.0-...`) both fail it, and both grant far more than DNS-01 needs. Pass the API token the variable's name asks for, not either of those. | _(unset)_ |
| `CROWDSEC_BOUNCER_KEY` | Bouncer API key (generate with `cscli bouncers add caddy`); read by the `caddy-crowdsec-bouncer` plugin via `{env.CROWDSEC_BOUNCER_KEY}`. | _(unset)_ |

Reference either credential only as `{env.VAR}`, never as a literal in the Caddyfile. The plugins resolve the placeholder at provision time, so the config the admin API serves at `GET /config/` keeps the placeholder; a hardcoded value comes back verbatim to anything that can reach that endpoint. This image does not declare `CADDY_VERSION`, unlike the official `caddy` image: the builder and the contract donor carry independent digest pins, so a copied version string could name a release the shipped binary is not, and a Caddyfile that reads `{env.CADDY_VERSION}` gets an empty value here and keeps serving.

### Volumes

| Mount | Description |
| --- | --- |
| `/etc/caddy` | The directory holding your `Caddyfile` (read-only is fine; mount the DIRECTORY, not the file: replacing a single-file bind mount with a new file leaves the container on the old inode and defeats every reload path; reload with `docker kill -s USR1 caddy`, or `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`) |
| `/data` | Caddy's data directory: issued certificates, ACME state, plugin storage. **Persist this** or you'll re-issue certs on every restart. |
| `/config` | (optional) Caddy's auto-generated JSON config and persistent state |

### Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| `80` | TCP | HTTP: HTTP-01 challenges and redirects to HTTPS |
| `443` | TCP | HTTPS / HTTP/2 |
| `443` | UDP | HTTP/3 (QUIC) |
| `2019` | TCP | Caddy's admin API (unauthenticated): loopback-bound by default, so publishing it reaches a listener that answers only inside the container |
| `2020` | TCP | Prometheus metrics, only if your Caddyfile opens the listener |

The admin API port is declared for documentation and for in-namespace scrapers; publishing it is only useful if a Caddyfile deliberately rebinds `admin` off loopback, and at that point it is an unauthenticated control plane on a routable address. The `2020` listener is a Caddyfile decision rather than an image one: nothing in the image opens it, the shipped [`Caddyfile.plugins.example`](./Caddyfile.plugins.example) does (`:2020 { metrics /metrics }`) and `Caddyfile.example` does not, and it is not in the image's `EXPOSE`. The compose example publishes no host port for it, but a site address with no host binds every interface in the container, so any container on the same Docker network can read the series.

### Running unprivileged

The image runs as **root** by default (the upstream Caddy default), so root binds ports 80 and 443 natively and the example needs no extra capability for them.

To run Caddy as a non-root user instead:

- set `user: "<uid>:<gid>"` on the service,
- `chown` the `/data` host directory to that UID (Caddy writes certs and ACME state there), and `chown` the `/config` host directory too if you mount one, because Caddy writes its config autosave under `/config/caddy` and the image's own `/config/caddy` is world-writable only while `/config` stays unmounted. If that mount is not writable Caddy keeps serving and logs `unable to autosave config` at ERROR; the sibling path logs `unable to create folder for config autosave` when `/config/caddy` cannot be created at all. Caddy attempts the autosave on every config it loads, so a wrong owner gives one line at startup and one more on every reload. That autosave is also what `--resume` reads, so `--resume` then has nothing to resume.

Under Docker's defaults that is all: containers start with `net.ipv4.ip_unprivileged_port_start=0`, so an unprivileged process binds 80/443 directly. `cap_add: [NET_BIND_SERVICE]` does **not** help a non-root user here: Docker grants added capabilities to root, and the binary carries no file capability. If your daemon hardens `ip_unprivileged_port_start`, restore it per container with `sysctls: ["net.ipv4.ip_unprivileged_port_start=0"]` instead.

## Alerting

The recommended rules ship as one file per expression language: the PromQL rules in [`alerts/promql.yaml`](alerts/promql.yaml) and the LogQL rules in [`alerts/logql.yaml`](alerts/logql.yaml). Load each file into its own ruler. A ruler parses every expression in the file it loads, and neither ruler parses the other's language, so one combined file loads in neither. Each rule's own prerequisites are stated in its file's header. The split follows the CONDITION rather than the app, because Caddy carries its operational state in two places:

- **The PromQL rules read metrics** (`alerts/promql.yaml`), served by the admin API's `/metrics` endpoint at `http://localhost:2019/metrics` (the example's `admin localhost:2019`), so keep the admin API enabled (it is on by default) and scrape it. That bind is loopback, so scrape from inside the container's network namespace (a monitoring sidecar) or scrape the routable listener the shipped `Caddyfile.plugins.example` already carries (`:2020`, in the Ports table above). Only `CaddyConfigReloadFailed` needs nothing further. `CaddyHigh5xxRate` needs the `metrics` global option, which is what registers the per-route HTTP instrumentation it reads and which the shipped `Caddyfile.plugins.example` sets. `CaddyUpstreamUnhealthy` needs active or passive health checks on your own `reverse_proxy`, which neither shipped example configures, and without them its series stays at 1 and the rule cannot fire. The bouncer's LAPI counters need `enable_caddy_metrics` in the `crowdsec` global block, which the shipped example does set. `Caddyfile.example` carries none of the three, so of the rules that read Caddy's own registry it gives `CaddyConfigReloadFailed` input and nothing else. Evaluate these with Prometheus or the Mimir ruler.
- **The LogQL rules read the container log** (`alerts/logql.yaml`), because their condition registers no series at all. Ship the container's logs to Loki and evaluate those with [Loki's ruler](https://grafana.com/docs/loki/latest/alert/). Caddy encodes its log as JSON whenever stderr is not an interactive terminal, which is the container default, so `| json` parses the stream and `logger` and `level` are the selectors. Every rule here but `CaddyReloadRejected` and `CaddyStartupFailed` is that shape. `CaddyReloadRejected` selects a message rather than a logger because Caddy reports it on the default logger. `CaddyStartupFailed` is different again: the CLI prints its line before that logger exists, so it carries no `logger` field and no `log` block can take it off stderr. One prerequisite is easy to miss: a global `log` block that sends the default logger to a file takes these lines off stderr, and none of them then matches anything except `CaddyStartupFailed`. Leave the default logger on stderr, or tail that file with your collector.

Firing alerts deliver through your Alertmanager either way. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `CaddyTargetDown` | no successful scrape of Caddy for 15m, so every metric rule here is blind | critical |
| `CaddyTargetAbsent` | there is no `up{job="caddy"}` series at all, so Caddy is not a configured target | critical |
| `CaddyUpstreamUnhealthy` | a `reverse_proxy` upstream's health check reports it down for >5m | warning |
| `CaddyConfigReloadFailed` | the last config reload was rejected, so the running config is stale | critical |
| `CaddyHigh5xxRate` | the 5xx share of the requests through one handler stays above 5% for 10 minutes, while the target as a whole carries more than 1 req/s over that same window | warning |
| `CaddyCrowdSecLAPIFailing` | more than half the bouncer's LAPI decision-stream polls have failed over a 10m window, sustained for 5m | warning |
| `CaddyCertIssuanceFailed` | Caddy logs more than 2 certificate errors in an hour while getting or renewing one | warning |
| `CaddyCertJobFailed` | a certificate job ends in an error, including a `/data` that cannot be read or written | warning |
| `CaddyCrowdSecLAPIPollFailed` | the bouncer logs more than 2 LAPI errors in 10 minutes, needing no Caddyfile option | warning |
| `CaddyConfigWatcherStopped` | an opted-in `--watch` could not read or adapt the config file, so the watcher stopped and later edits are ignored | critical |
| `CaddyReloadRejected` | a requested config reload was refused, so the file on disk is not the running config | critical |
| `CaddyStartupFailed` | Caddy exits during startup, before it serves anything | critical |

Thresholds and the `severity` labels are starting points; add your scrape `job` label to the selectors that read Caddy's own registry if you scrape more than one instance, and set it on the reachability pair, which requires it; adjust the `container` selector on the log rules to whatever your log collector sets, and route by whatever labels your Alertmanager uses.

No metric covers certificate renewal, because Caddy registers no certificate, ACME or expiry series. The log does: certmagic reports a failure at ERROR under `tls.renew` for a renewal and `tls.obtain` for a first issuance, as `could not get certificate from issuer` once per issuer per attempt, then `will retry` or `final attempt; giving up`. `CaddyCertIssuanceFailed` matches those. Keep a TLS prober against the served site as well (blackbox_exporter's `probe_ssl_earliest_cert_expiry`), because it catches the case that logs nothing: a certificate certmagic does not manage, such as one loaded from files with `tls <cert> <key>`, which is never renewed and never reported.

## Healthcheck

The image ships a **liveness** healthcheck: the bundled `/probe` binary (from [`cplieger/health`](https://github.com/cplieger/health); the runtime has no shell or wget) GETs Caddy's admin API at `http://127.0.0.1:2019/config/`, which is enabled by default. This confirms Caddy is up and the admin plane is responsive (it catches faults like a hung reload that keep serving traffic while the admin API is dead). It does not confirm a config is loaded: `GET /config/` answers 200 with a body of `null` once the config has been stopped or deleted, and the probe reads the status only. Under this image's own command a config that fails to load exits the process, so reaching that state takes a command override or a `DELETE /config/`; `caddy_config_last_reload_successful`, which the shipped `CaddyConfigReloadFailed` rule keys on, is what covers it. The probe works out of the box for **any** Caddyfile; no route configuration required.

Each probe is an admin-API request, and Caddy logs every admin-API request except `/metrics` at INFO on the `admin.api` logger: one ~200-byte record per interval, 2880 a day at the baked 30s interval, for the life of the container. With the minimal `Caddyfile.example`, which configures no per-site `log` and so has no access log, those records are the whole steady-state content of the stream the [Alerting](#alerting) section asks you to ship to Loki. No shipped rule selects them, so alerting is unaffected; the cost is volume and readability. To drop them without losing the admin plane's own errors, configure two logs in your global options block:

```caddy
log {
	exclude admin.api
}
log adminerrors {
	include admin.api
	level ERROR
}
```

Caddy admits a message into every log whose include/exclude list accepts it, and each log has its own minimum level, so the first block takes the INFO records off the default log while the second keeps the `admin.api` ERROR records a failing admin request emits. `output` defaults to stderr and `format` to JSON off a terminal, so neither block needs either. A lone `log { exclude admin.api }` is level-blind and drops the ERROR records too.

> **Note:** the default probe hits Caddy's admin API. If your Caddyfile sets `admin off` or rebinds the admin endpoint, this probe fails even though Caddy is serving normally; switch to the end-to-end `/health` override below in that case.

For an **end-to-end** check that verifies the proxy is actually serving traffic (listener bound, routing works), override the healthcheck to probe a `/health` route. Both bundled examples serve one on plaintext `:80` ([`Caddyfile.example`](./Caddyfile.example) and [`Caddyfile.plugins.example`](./Caddyfile.plugins.example)):

```caddy
http://:80 {
    respond /health 200
    respond 404
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

The probe exits zero only when every URL answers 2xx, and non-zero otherwise, which is all
Docker's health state distinguishes; a failure is written to stderr and surfaces in `docker
inspect --format '{{json .State.Health}}'`. The exit-code table and the stderr diagnostics are
[`cplieger/health`](https://github.com/cplieger/health)'s contract, not this image's. Override the timing in your compose for tighter detection windows regardless of which probe you use.

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
> **Fail-open by default.** If the LAPI is unreachable the bouncer stops learning decisions, without failing a single request and without a healthcheck transition. It does report the outage in the log: every failed decision-stream poll is one ERROR line under the `crowdsec` logger, with no Caddyfile option needed; `CaddyCrowdSecLAPIPollFailed`'s own description in `alerts/logql.yaml` owns the cadence, which is not one number (an established stream polls on the default interval, while a LAPI that never answers from startup is retried much faster than that). `alerts/logql.yaml`'s `CaddyCrowdSecLAPIPollFailed` matches those on `{container="caddy"} | json | logger="crowdsec" | level="error"`. A metric reports the same outage as a rate rather than a presence, once `enable_caddy_metrics` is set in the `crowdsec` global block; the shipped `Caddyfile.plugins.example` sets it, and `CaddyCrowdSecLAPIFailing` reads it. What enforcement survives the outage depends on the cache. With a warm cache, which is every case except an outage starting before the first decision-stream response, the decisions already cached keep being enforced for as long as the outage lasts; what stops is the learning, so no new decision arrives and no expiry is applied, and the enforced list silently ages. With a cold cache, an outage that begins before that first response, nothing is enforced. Set `enable_hard_fails` in the `crowdsec` global block and the bouncer logs at FATAL and exits instead, so the container restarts rather than serving unblocked; the tradeoff is that a CrowdSec outage then becomes an outage of everything behind the proxy, which is why the default is the other way. The bouncer's own reachability check is on the admin API, `curl -XPOST http://127.0.0.1:2019/crowdsec/health`, which answers `{"Ok":false}` while the LAPI is unreachable (the capital is the plugin's own JSON shape across all of its admin endpoints, so match on it exactly). It pings the LAPI through the live bouncer and reads no decision, so what it reports is reachability, not what any request was allowed to do. Treat it as a manual or sidecar diagnostic: it answers only POST (a GET is 405'd, so the bundled `/probe` cannot be pointed at it) and it reports the outage in the body while returning HTTP 200, so a status-only prober reads it as success. Its value is an answer for one instance on demand; both shipped rules detect the same outage without it. No surface in this bundle reports the fail-open verdict itself.

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
