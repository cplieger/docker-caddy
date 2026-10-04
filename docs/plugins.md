# Plugins

This page explains the two plugins compiled into this image, and how the CrowdSec bouncer behaves when the CrowdSec Local API (LAPI) is down. It is for operators deciding how much to rely on the bouncer. Each plugin's own README has its full set of options.

## caddy-dns/cloudflare

[caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) adds the `cloudflare` DNS provider to Caddy's `tls` directive, so Caddy answers DNS-01 ACME challenges through the Cloudflare API. DNS-01 proves you own a domain through a DNS record, which helps in two cases:

- Wildcard certificates such as `*.example.com`, which only DNS-01 can issue.
- Services that only your own network can reach, where the HTTP-01 and TLS-ALPN-01 challenges cannot work.

## caddy-crowdsec-bouncer

[caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) checks every request against a cached copy of CrowdSec's active decision list and blocks the listed IP addresses. A streaming subscription to the LAPI keeps the cache current, so no request waits on a network round trip. CrowdSec scenarios such as HTTP probes, scrapers and brute-force attempts create the decisions this bouncer enforces at the proxy.

This image builds in the plugin's HTTP handler only. The plugin's AppSec handler and its Layer 4 connection matcher are separate modules, so neither is in this image.

### It only enforces

The bouncer pulls the active decision list from the LAPI and blocks IP addresses. It does not run the CrowdSec engine, create alerts or touch the engine's database, so a healthy bouncer says nothing about whether CrowdSec detects anything. The engine and its database run separately, so configure them with [CrowdSec's database guidance](https://docs.crowdsec.net/docs/configuration/crowdsec_configuration/#use_wal). For an SQLite database that is not on a network share, CrowdSec recommends `use_wal: true`.

### When the LAPI is down

By default the bouncer fails open. When it cannot reach the LAPI it stops learning decisions, fails no request and does not change the healthcheck.

What it still enforces depends on its cache. With a warm cache, which is every case except an outage that starts before the first decision-stream response, it keeps enforcing the decisions it already has for as long as the outage lasts. It learns no new decision and applies no expiry, so the enforced list ages without notice. With a cold cache, an outage that starts before that first response, it enforces nothing.

The bouncer does report the outage. Every failed decision-stream poll writes one ERROR line under the `crowdsec` logger, with no Caddyfile option needed. The `CaddyCrowdSecLAPIPollFailed` rule in [`alerts/logql.yaml`](../alerts/logql.yaml) matches those lines with `{container="caddy"} | json | logger="crowdsec" | level="error"`, and its own description gives the polling cadence. That cadence is not one number. An established stream polls on the default interval, while a LAPI that never answered since startup is retried much faster. A metric reports the same outage as a rate once `enable_caddy_metrics` is set in the `crowdsec` global block. `Caddyfile.plugins.example` sets it, and `CaddyCrowdSecLAPIFailing` reads it.

Set `enable_hard_fails` in the `crowdsec` global block to make the bouncer log at FATAL and exit instead, so the container restarts rather than serving unblocked. A CrowdSec outage then takes down everything behind the proxy, which is why the default is the other way.

### Checking the bouncer by hand

The bouncer's own reachability check is on the admin API, `curl -XPOST http://127.0.0.1:2019/crowdsec/health`, run from something that shares the container's network namespace. It answers `{"Ok":false}` while the LAPI is unreachable. The capital letter is the plugin's own JSON shape across all its admin endpoints, so match it exactly.

It pings the LAPI through the live bouncer and reads no decision, so it reports reachability, not what any request was allowed to do. Use it as a manual or sidecar check. It answers only POST, and a GET gets a 405, so the bundled `/probe` cannot use it. It reports the outage in the body with an HTTP 200, so a prober that reads only the status counts it as a success. Both shipped rules detect the same outage without it. Nothing in this image reports the fail-open decision itself.
