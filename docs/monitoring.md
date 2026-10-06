# Monitoring and alerts

This page lists what Caddy emits, the alert rules this repository ships and what each rule needs from your Caddyfile and your collector. It is for operators who run Prometheus, Loki and Alertmanager.

## What Caddy emits

Caddy serves Prometheus metrics at `/metrics` on its admin API, `http://localhost:2019/metrics` with the examples' `admin localhost:2019`. That address is on the container's loopback, so scrape it from something that shares the container's network namespace, such as a monitoring sidecar. The alternative is the routable `:2020` listener that `Caddyfile.plugins.example` already opens. Both serve the same registry. Keep the admin API enabled, as it is by default.

Caddy writes its log as JSON whenever standard error is not an interactive terminal, which is the case in a container. A `| json` stage parses it, and `logger` and `level` are the fields to select on. Caddy's logging library, zap, writes the level in lowercase, so match `level="error"`, never `level="ERROR"`.

## Alerting

The six PromQL rules in [`alerts/promql.yaml`](../alerts/promql.yaml) go to Prometheus or the Mimir ruler, and the five LogQL rules in [`alerts/logql.yaml`](../alerts/logql.yaml) go to Loki's ruler. [Loading metric alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-metric-alert-rules) and [Loading an app's alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-an-apps-alert-rules) show how.

The log rules cover conditions with no series a Prometheus ruler can rely on. Caddy registers no series at all for some of them. The others have one only when a Caddyfile option is set, or only for some of their causes. The sections below the table say what each rule needs and how it behaves.

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

Thresholds, `for:` windows and the `severity` labels are starting points. If you scrape more than one instance, add your scrape `job` label to the selectors that read Caddy's own registry, and set it on the reachability pair, which requires it. Change the `container` selector on the log rules to the label your log collector sets. Route by whatever labels your Alertmanager uses.

### What the PromQL rules need

`CaddyTargetDown` and `CaddyTargetAbsent` read Prometheus's own `up` series rather than Caddy's registry, so no Caddyfile option gives them input. Their `job="caddy"` matcher must name your scrape job. Without it, `up == 0` fires for every unrelated target in your Prometheus. `absent()` takes its labels from equality matchers, so the matcher is also what gives that alert its `job` label.

The other four read Caddy's registry, and their needs differ.

- `CaddyConfigReloadFailed` needs nothing further, because Caddy registers its metric unconditionally.
- `CaddyHigh5xxRate` needs the `metrics` global option, which registers the per-route HTTP instrumentation it reads. `Caddyfile.plugins.example` sets it, and the comment at that line states the throughput cost Caddy documents for it.
- `CaddyUpstreamUnhealthy` needs active or passive health checks on your own `reverse_proxy`, because Caddy performs none by default. Caddy registers its metric unconditionally, but without health checks the series stays at 1 and the rule cannot fire. For passive checks, `fail_duration <duration>` is enough. Give it the duration, because the bare option name makes a Caddyfile that fails to adapt. Neither example configures health checks, and `Caddyfile.plugins.example` says so at its `reverse_proxy` line.
- `CaddyCrowdSecLAPIFailing` reads the bouncer's LAPI counters, which need `enable_caddy_metrics` in the `crowdsec` global block. It also needs the default streaming bouncer. With `disable_streaming`, the bouncer makes no decision-stream poll, so both of the rule's `mode="stream"` selectors have no series. `Caddyfile.plugins.example` satisfies both.

`Caddyfile.example` sets none of the three options and opens no `:2020` listener, so with it only `CaddyConfigReloadFailed` has input among the rules that read Caddy's registry.

### What the LogQL rules need

Ship the container's logs to Loki. Grafana Alloy's Docker log discovery sets the `container` label with no configuration. Promtail and other collectors may key on `job` or `service` instead.

`CaddyCertManagementFailing` and `CaddyCrowdSecLAPIPollFailed` select on `logger` and `level` after `| json`. `CaddyConfigWatcherStopped` selects the `watcher` logger. `CaddyReloadRejected` selects a message instead, because Caddy reports it on the default logger. It needs the log destination below but not the JSON encoding. `CaddyStartupFailed` selects the raw cause line.

A global `log` block that sends the default logger to a file takes these lines off standard error, and then none of the log rules matches anything. Leave the default logger on standard error, or have your collector read that file.

### Log records that can carry a credential

The log stream can carry a live Cloudflare API token. A module that refuses a credential prints it inside its own error text, and the bundled Cloudflare DNS plugin prints the token it refused. Any record that reports a failed config load can therefore carry one. Choose the store's retention and who can read it with that in mind.

At startup, that record is the cause line `CaddyStartupFailed` selects. On a reload, the token can appear in the structured `error` field of three records. One is the `failed to reload config from file` line that `CaddyReloadRejected` selects. The other two are the watcher's `applying latest config` and the admin API's `request error`, which reach the store with no rule here selecting them.

For a Caddyfile that reads the token through `{env.VAR}`, the adapt cause is the exception. `caddy adapt` never resolves that placeholder form, so an `adapting config using caddyfile:` cause carries no credential. Treat any token that appears in any of these records as exposed, and rotate it.

### Reachability rules

Prometheus creates one `up` series for each configured target. `CaddyTargetDown` fires when Caddy is a target but cannot be scraped, and it keeps firing until a scrape succeeds. Every rule that reads Caddy's registry is blind at the same time. `CaddyTargetAbsent` fires when no target exists, and it keeps firing until one does.

A target goes missing when it is dropped, its scrape config is removed or its pod is deleted. `CaddyTargetAbsent` also fires when the `job="caddy"` matcher does not name your scrape job. Caddy may then be scraped and healthy under another name, so set the matcher on both rules to the name your scrape config uses. For a log-only deployment, load only `alerts/logql.yaml` and leave both reachability rules out.

### Config load rules

Four rules cover a config that Caddy cannot load, and each sees different causes. The `caddy_config_last_reload_successful` gauge moves only when Caddy tries to apply a config in its running process. A config that fails to read or adapt never reaches that step, so it leaves the gauge at 1. The table shows which signal reports each case.

| How the config is loaded | Fails to read or adapt | Fails to apply |
| --- | --- | --- |
| At startup, by the image's own command | `CaddyStartupFailed` on Caddy v2.11.4 and earlier, only the restart loop on later versions | `CaddyStartupFailed` |
| A SIGUSR1 reload | `CaddyReloadRejected` | `CaddyReloadRejected` and `CaddyConfigReloadFailed` |
| An opted-in `--watch` poll | `CaddyConfigWatcherStopped` | `CaddyConfigReloadFailed` |
| `caddy reload` through `docker exec` | the command's exit status | the command's exit status and `CaddyConfigReloadFailed` |

`CaddyConfigReloadFailed` reads the gauge. At startup, a config that fails to apply ends the process before the gauge has a series, so `CaddyStartupFailed` reports it there. On every reload path, the previous config keeps running until a good one loads.

#### `CaddyReloadRejected`

This rule covers a SIGUSR1 reload, which is the reload path a deployment on the image's own command has. For a file that fails to read or adapt, it is the only signal. `CaddyConfigWatcherStopped` needs an opted-in `--watch`, and `CaddyStartupFailed` sees only a failure at process start. The proxy keeps serving the last good config, and the healthcheck stays green.

Read the structured `error` field for the cause. `reading config from file:` is a missing or unreadable file. `adapting config using caddyfile:` is a Caddyfile that does not parse. A `loading new config` cause is a config that read and adapted and then failed to apply, and it is the only cause that moves the gauge.

The line carries no `logger` field, because Caddy writes it on the default logger, so the rule selects the message. Caddy logs it once per signal, so the alert reports the change and clears when its one-hour window passes. To recover, fix the file and send the signal again. `caddy validate --adapter caddyfile --config <file>` catches the first two causes before you send it. A `caddy reload` through `docker exec` needs no rule, because it reports the same failure as its own exit status.

#### `CaddyConfigWatcherStopped`

This rule matches `unable to load latest config` under the `watcher` logger. The watcher logs it when an opted-in `--watch` cannot read or adapt the current file, and then stops polling for the life of the process. A deployment that keeps the image's own command never arms the watcher and never sees this alert.

Read the structured `error` field for the cause. `reading config from file:` is a missing or unreadable file. `adapting config using caddyfile:` is a Caddyfile that does not parse. `config is not valid JSON:` is a JSON config watched without `--adapter`. Each needs a different repair, and each leaves the watcher stopped.

Caddy keeps serving the last good config and ignores later valid edits. Nothing else reports it. The gauge stays at 1 because Caddy attempted no load, and the container stays healthy. Restart the container once the file is readable and valid again. An explicit reload applies the current file but does not restart the watcher.

The rule selects the message, not the level. The watcher also logs `applying latest config` at ERROR when a good file fails to apply. That case keeps polling and moves the gauge, so `CaddyConfigReloadFailed` reports it. The stop line is logged once, so the alert reports the change and clears when its one-hour window passes, while the watcher stays stopped. Lengthen the window if you want the alert to last longer.

A replaced file is none of these causes, and the rule cannot see it. With the config folder mounted, the poller reads a renamed file cleanly on its next poll. With the single file bind-mounted, the mount pins the old inode, so the poller keeps reading the old bytes and logs nothing. Mount the folder, or save the file in place.

#### `CaddyStartupFailed`

This rule fires when Caddy exits before it serves anything. The process ends before the admin endpoint or a `metrics` listener binds, so no metric series exists to report it. With `restart: unless-stopped`, the container loops and the line repeats on every attempt.

The line names the cause. `adapting config using caddyfile:` is a Caddyfile that does not parse. `reading config from file:` is a missing or unreadable file, and with a single-file bind mount it also means the mount source does not exist. `loading initial config:` is a config that read and adapted and then failed to apply. Its cause is a module that would not provision, such as a rejected credential, or an address already in use.

`caddy validate --adapter caddyfile --config <file>` catches the first two causes and the provisioning half of the third. It never catches an address conflict.

How the cause reaches the log depends on the Caddy version. Up to v2.11.4, the CLI prints a plain-text `Error: <cause>` line on standard error for all three causes, whatever the Caddyfile's `log` block says. From v2.11.5, it writes the cause through Caddy's own logger as an `error` record whose `msg` is the cause, as [caddyserver/caddy#7962](https://github.com/caddyserver/caddy/issues/7962) describes.

The Caddy in this image behaves the second way, and two things follow. The read and adapt causes go into a startup buffer that nothing flushes, so Caddy never prints them. The container exits with status 1 after its startup INFO lines, and the restart loop is the only signal. The load cause is printed wherever the Caddyfile's default logger writes, so the rule sees it only with that logger on standard error in JSON.

The selector has no `| json` stage. Its first alternative is the plain-text line older versions print, and a `| json` stage would tag that line with a parse error and fail the query. Keeping it lets one rule serve an image on either side of v2.11.5. The second alternative, the JSON record later versions print, is anchored on `"msg":"` to keep it off the reload and watcher records. Those carry the same cause text in their `error` field while Caddy keeps serving.

### The 5xx rate

`CaddyHigh5xxRate` computes the 5xx share per handler over a 5-minute rate and fires when it stays above 5% for 10 minutes. It also requires the target as a whole to carry more than 1 observation per second over the same window. That throughput floor is aggregate on purpose, so a handler's bad share pages once the target carries traffic, even when that handler is quiet. A firing alert usually means a failing upstream or a broken route, so compare it with `CaddyUpstreamUnhealthy` and the backend logs.

The histogram counts one observation per matched top-level route, not one per request. Keeping the `handler` label is what makes the ratio a request share. A request observes once per matched route of that handler, which is once under the usual layout of one directive per handler. Aggregating the label away would weight every request by how many routes it traversed. Two routes that share a handler name, such as two `header` directives with overlapping matchers, make it an observation share again for that handler.

How many `handler` values a deployment has depends on its site addresses, not on how many site blocks it writes. A block whose address carries a host or a path adapts to one terminal route that wraps a `subroute` handler. Every request it serves is then observed once, under `handler="subroute"`. A block whose address carries neither, and is the only block on its listener, is flattened to one non-terminal route per directive. A request is then observed once per matched route, and the `handler` label keeps the number a request share.

The `metrics { per_host }` option adds a `host` label. The expression keeps it automatically, which turns the rule into one alert per virtual host. Caddy's documentation for the option names its cardinality and memory cost.

### CrowdSec bouncer

Two rules report a LAPI outage. `CaddyCrowdSecLAPIPollFailed` reads the log and needs no Caddyfile option, so it is the detector for a deployment that leaves `enable_caddy_metrics` off or sets `disable_streaming`. Where the metrics are on, `CaddyCrowdSecLAPIFailing` reports the same outage as a rate. With `enable_hard_fails` set, the bouncer logs at FATAL and exits instead, so the container restart is the signal rather than either rule.

During an outage the proxy keeps serving and the healthcheck stays green. What the bouncer still enforces depends on its cache. With a warm cache, which is every case except an outage that starts before the first decision-stream response, it keeps enforcing the decisions it already has. It learns no new decision and applies no expiry, so the enforced list ages without notice. With a cold cache it enforces nothing.

Neither rule reports the fail-open verdict itself. They detect the LAPI outage that causes it. The admin API's `POST /crowdsec/health` is another reachability check. It pings the LAPI through the live bouncer and inspects no decision, so it reports reachability, not a verdict. [Plugins](plugins.md) covers the bouncer's behavior in full.

Under the default streaming bouncer, each failed poll logs one ERROR line. An established stream polls every 60s by default, so a LAPI that starts failing passes the threshold of 2 lines in about 2 to 3 minutes. One lost poll on an established stream stays quiet. Under `disable_streaming`, the bouncer logs the line per request instead, so the cadence follows traffic rather than the poll interval.

A LAPI unreachable from startup is retried after a 10s delay. When the connection fails fast, as a refused connection or a DNS failure does, only the two retry delays pass, and the third ERROR arrives about 20 seconds in. When the LAPI is blackholed, it arrives about 50 seconds in, because each attempt also waits out its own 10s deadline before the delay starts.

`CaddyCrowdSecLAPIPollFailed` selects the ERROR level under the `crowdsec` logger rather than a message, because a failed poll logs the raw transport error and has no stable string. Any other repeating bouncer error trips the same rule, so read the line.

### Certificates

No metric covers certificate renewal, because Caddy registers no certificate, ACME or expiry series. The log does, and `CaddyCertManagementFailing` reads it.

Certmagic is the library Caddy manages certificates with. The rule fires when certmagic has logged an ERROR for a certificate subject in the last hour, and no `certificate obtained successfully` or `certificate renewed successfully` for that subject, and that has held for 15 minutes. The failures are ERROR lines under `tls.obtain` for a first issuance and `tls.renew` for a renewal, such as `could not get certificate from issuer` and `will retry`. The base `tls` logger adds `job failed` and `initiating certificate management`.

The rule compares failures with successes per subject instead of counting lines, so the number of issuers and the number of lines one attempt logs do not change when it fires. A retry that recovers within 15 minutes stays quiet. A failure that persists keeps firing until that subject logs a success or its last failure is an hour old. One certificate renewing cannot hide another that is failing. A subject that renewed earlier in the hour and then starts failing is reported once that success is an hour old.

Certmagic names the subject in an `identifier` or `subject` field. The exceptions are `job failed` and the retry loop's `will retry` and `final attempt; giving up`, which carry it only at the start of their `error` text, as `[name] ...` or `name: obtaining certificate: ...`. The rule reads the subject from there. A failure whose subject it cannot read gets an empty subject, which no success matches, so it still fires. A line the log driver cut short still counts rather than failing the query.

Lines carrying `context canceled` are excluded. A successful config load cancels the outgoing config's context, which ends any certificate job that config had in flight, and the new config starts its own. An opted-in `--watch` can reload after its 1-second poll.

Read the `error` field for the cause. An issuer may have refused the order or been unreachable. A DNS-01 credential may have been rejected, such as the Cloudflare API token for a `dns cloudflare` site. A `/data` volume that cannot be written logs `failed storage check`, and a stored certificate that cannot be read logs a `caching certificate` error. The cause can also be a lock.

A retry loop runs for a first issuance, and for a renewal Caddy starts at boot for a certificate that is already due. Inside it, every attempt after the first goes to the ACME issuer's test endpoint when it has one. With the CA left at its default, that is the staging endpoint at `acme-staging-v02.api.letsencrypt.org`, and an explicit `test_ca` sets a different one. An order that succeeds there and is then refused in production ends the retries, so read the `error` field before you check the volume.

On a renewal, the served certificate stays valid until it expires, so the alert fires while HTTPS still works.

Keep a TLS prober against the served site as well, such as blackbox_exporter's `probe_ssl_earliest_cert_expiry`. It catches the case that logs nothing, a certificate certmagic does not manage. One loaded from files with `tls <cert> <key>` is never renewed and never reported.
