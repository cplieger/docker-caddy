# Troubleshooting

This page covers what the built-in healthcheck proves, how to make it check your sites too, and how to quiet the log lines it causes. It is for operators who rely on the container's health state.

## What the healthcheck checks

The image ships a liveness check. Every 30 seconds the bundled `/probe` binary from [cplieger/health](https://github.com/cplieger/health) sends a GET to Caddy's admin API at `http://127.0.0.1:2019/config/`, which is on by default. The runtime has no shell or `wget`, so `/probe` is the only HTTP client in it. The check needs no route of its own, but it requires the admin API at `127.0.0.1:2019`.

A healthy result means Caddy is up and its admin API answers. It catches faults such as a hung reload, where Caddy keeps serving traffic while the admin API is dead. It does not confirm that a config is loaded. `GET /config/` answers 200 with a body of `null` once the config has been stopped or deleted, and the probe reads only the status. Under the image's own command, a config that fails to load ends the process, so reaching that state takes a command override or a `DELETE /config/`. The `caddy_config_last_reload_successful` metric, which the shipped `CaddyConfigReloadFailed` rule reads, covers it.

The healthcheck never reports a dead Caddy. `caddy` is PID 1 with no entrypoint in front of it, so a rejected Caddyfile or a listener that cannot bind stops the container with exit status 1. The restart policy reacts, not the healthcheck. `CaddyStartupFailed` in [Monitoring and alerts](monitoring.md) says which of those causes print a line it can match. A restart reads the Caddyfile again and re-evaluates certificate renewal, and it schedules nothing else.

A Caddyfile that sets `admin off` or moves the admin address makes this probe fail even though Caddy serves normally. Use the end-to-end check below in that case.

## Check the serving path too

To check that the proxy really serves traffic, with its listener bound and routing working, override the healthcheck to probe a `/health` route. Both example Caddyfiles serve one on plain HTTP port 80. It has to live in an explicit `http://:80` block, because Caddy redirects port 80 to 443 for HTTPS site blocks, and a `/health` route inside one would answer 308 instead of serving over plain HTTP. Then override the healthcheck in your compose file:

```yaml
healthcheck:
  test: ["CMD", "/probe", "-timeout", "4s", "http://127.0.0.1:80/health"]
```

The probe accepts several URLs, and every one must answer with a 2xx status within the shared `-timeout` budget. Keep `-timeout` at 4s as shown, below Docker's 5s healthcheck timeout, so a slow endpoint is reported instead of killed. One healthcheck can then watch the serving path and the admin API:

```yaml
healthcheck:
  test: ["CMD", "/probe", "-timeout", "4s", "http://127.0.0.1:80/health", "http://127.0.0.1:2019/config/"]
```

The probe exits with zero only when every URL answers with a 2xx status, and with a non-zero status otherwise, which is all Docker's health state tells apart. A failure is written to standard error and shows up in `docker inspect --format '{{json .State.Health}}' caddy`. The exit codes and the error messages belong to [cplieger/health](https://github.com/cplieger/health), not to this image. You can override the timing in your compose file for faster detection with either probe.

## Quieter admin logs

Each probe is an admin API request. Caddy logs every admin API request except `/metrics` at INFO on the `admin.api` logger, which is one record of about 200 bytes per probe. At the 30-second interval that is 2,880 records a day for the life of the container. `Caddyfile.example` sets no per-site `log`, so it has no access log. With it, those records are all the container logs in steady state, and they fill the stream [Monitoring and alerts](monitoring.md) asks you to ship to Loki. No shipped rule reads them, so alerting is unaffected. The cost is volume and readability.

The probe stays on `/config/` rather than on the quieter `/metrics` on purpose. Reading the config takes the same lock a reload holds, so a reload stuck in provisioning fails the probe, while `/metrics` is served from a registry captured at startup and answers 200 throughout.

To drop the INFO records and keep the admin API's own errors, configure two logs in your global options block:

```caddy
log {
	exclude admin.api
}
log adminerrors {
	include admin.api
	level ERROR
}
```

Caddy admits a message into every log whose include or exclude list accepts it, and each log has its own minimum level. The first block takes the INFO records off the default log, and the second keeps the `admin.api` ERROR records that a failing admin request writes. `output` defaults to standard error and `format` to JSON when no terminal is attached, so neither block needs them. A lone `log { exclude admin.api }` ignores levels and drops the ERROR records too.
