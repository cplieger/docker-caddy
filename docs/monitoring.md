# Monitoring and alerts

This page lists what Caddy emits, the alert rules this repository ships and what each rule needs from your Caddyfile and your collector. It is for operators who run Prometheus, Loki and Alertmanager.

## What Caddy emits

Caddy serves Prometheus metrics at `/metrics` on its admin API, `http://localhost:2019/metrics` with the examples' `admin localhost:2019`. That address is on the container's loopback, so scrape it from something that shares the container's network namespace, such as a monitoring sidecar. The alternative is the routable `:2020` listener that `Caddyfile.plugins.example` already opens. Both serve the same registry. Keep the admin API enabled, as it is by default.

Caddy writes its log as JSON whenever standard error is not an interactive terminal, which is the case in a container. A `| json` stage parses it, and `logger` and `level` are the fields to select on. The level is lowercase, so match `level="error"`, never `level="ERROR"`.

## Alerting

The rules ship as one file per expression language, because each ruler parses every expression in the file it loads and neither parses the other's language. The six PromQL rules in [`alerts/promql.yaml`](../alerts/promql.yaml) go to Prometheus or the Mimir ruler. The five LogQL rules in [`alerts/logql.yaml`](../alerts/logql.yaml) go to [Loki's ruler](https://grafana.com/docs/loki/latest/alert/). The log rules exist because their conditions leave no series to read at all. Each file's header states each rule's prerequisites, and firing alerts go through your Alertmanager either way.

| Alert | Fires when | Severity |
| --- | --- | --- |
| `CaddyTargetDown` | no successful scrape of Caddy for 15 minutes, so every metric rule is blind | critical |
| `CaddyTargetAbsent` | there is no `up{job="caddy"}` series at all, so Caddy is not a configured target | critical |
| `CaddyUpstreamUnhealthy` | a `reverse_proxy` upstream's health check reports it down for more than 5 minutes | warning |
| `CaddyConfigReloadFailed` | the last config reload was rejected, so the running config is stale | critical |
| `CaddyHigh5xxRate` | one handler's 5xx share stays above 5% for 10 minutes while the target as a whole carries more than 1 request per second | warning |
| `CaddyCrowdSecLAPIFailing` | more than half the bouncer's LAPI decision-stream polls failed over 10 minutes, for 5 minutes | warning |
| `CaddyCertManagementFailing` | a certificate subject logged a failure and no success within the hour, for 15 minutes | warning |
| `CaddyCrowdSecLAPIPollFailed` | the bouncer logs more than 2 LAPI errors in 10 minutes, with no Caddyfile option needed | warning |
| `CaddyConfigWatcherStopped` | an opted-in `--watch` could not read or adapt the config file, so later edits are ignored | critical |
| `CaddyReloadRejected` | a requested config reload was refused, so the file on disk is not the running config | critical |
| `CaddyStartupFailed` | Caddy exits during startup, before it serves anything, on a config that fails to load | critical |

Thresholds and the `severity` labels are starting points. If you scrape more than one instance, add your scrape `job` label to the selectors that read Caddy's own registry, and set it on the reachability pair, which requires it. Change the `container` selector on the log rules to the label your log collector sets. Route by whatever labels your Alertmanager uses.

### What the PromQL rules need

`CaddyTargetDown` and `CaddyTargetAbsent` read Prometheus's own `up` series rather than Caddy's registry, so no Caddyfile option gives them input. Their `job="caddy"` matcher must name your scrape job.

The other four read Caddy's registry, and their needs differ.

- `CaddyConfigReloadFailed` needs nothing further.
- `CaddyHigh5xxRate` needs the `metrics` global option, which registers the per-route HTTP instrumentation it reads. `Caddyfile.plugins.example` sets it.
- `CaddyUpstreamUnhealthy` needs active or passive health checks on your own `reverse_proxy`, which neither example configures. Without them its series stays at 1 and the rule cannot fire.
- `CaddyCrowdSecLAPIFailing` reads the bouncer's LAPI counters, which need `enable_caddy_metrics` in the `crowdsec` global block. `Caddyfile.plugins.example` sets it.

`Caddyfile.example` sets none of the three options, so with it only `CaddyConfigReloadFailed` has input among the rules that read Caddy's registry.

### What the LogQL rules need

Ship the container's logs to Loki. `CaddyCertManagementFailing` and `CaddyCrowdSecLAPIPollFailed` select on `logger` and `level` after `| json`. `CaddyConfigWatcherStopped` selects the `watcher` logger. `CaddyReloadRejected` selects a message instead, because Caddy reports it on the default logger. `CaddyStartupFailed` selects the raw cause line.

The Caddy in this image reports a config that fails to load as a JSON record on the default logger. It prints nothing at all for a config file it cannot read or a Caddyfile that does not parse ([caddyserver/caddy#7962](https://github.com/caddyserver/caddy/issues/7962)), so for those two the container's restart loop is the only signal.

A global `log` block that sends the default logger to a file takes these lines off standard error, and then none of the log rules matches anything. Leave the default logger on standard error, or have your collector read that file.

The log stream can carry a live Cloudflare API token, because a credential a module refuses appears in that module's error text. Choose the store's retention and who can read it with that in mind. The header of `alerts/logql.yaml` names each record that can carry one.

### Certificates

No metric covers certificate renewal, because Caddy registers no certificate, ACME or expiry series. The log does, and `CaddyCertManagementFailing` reads it.

Certmagic is the library Caddy manages certificates with. The rule fires when certmagic has logged an ERROR for a certificate subject in the last hour, and no `certificate obtained successfully` or `certificate renewed successfully` for that subject, and that has held for 15 minutes. The failures are lines under `tls.obtain` for a first issuance, under `tls.renew` for a renewal, or a failed certificate job on the base `tls` logger. The rule compares failures with successes per subject instead of counting lines. A retry that recovers within 15 minutes stays quiet, and one certificate renewing cannot hide another that is failing.

Keep a TLS prober against the served site as well, such as blackbox_exporter's `probe_ssl_earliest_cert_expiry`. It catches the case that logs nothing, a certificate certmagic does not manage. One loaded from files with `tls <cert> <key>` is never renewed and never reported.
