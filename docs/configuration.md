# Configuration

This page covers the two credentials, reloading, watch mode, the admin API and the metrics listener. It is for readers who already have the quick start running. Caddy's own directives are in [Caddy's documentation](https://caddyserver.com/docs/caddyfile).

## Starting points

The repository ships two example Caddyfiles. The build checks both against the shipped binary. Each adapts with no warning, and `Caddyfile.plugins.example` loads once both credentials are set.

- [`Caddyfile.plugins.example`](../Caddyfile.plugins.example) uses both plugins. It carries the `crowdsec` global block, a `:2020` metrics listener, a `/health` route on plain HTTP and a wildcard site that gets its certificate through `dns cloudflare`.
- [`Caddyfile.example`](../Caddyfile.example) is plain Caddy with a `/health` route. It uses neither plugin, so it needs neither credential.

Copy either one to `caddy/Caddyfile` beside `compose.yaml`.

## Credentials

Caddy reads environment variables only where the Caddyfile names them as `{env.VAR}`. The compose example passes `CLOUDFLARE_API_TOKEN` and `CROWDSEC_BOUNCER_KEY`, and defaults both to empty rather than refusing to start. Each plugin refuses to provision with an empty credential, so Caddy exits at startup and the restart policy starts it again. Set both before the first start.

Write each credential only as its `{env.VAR}` placeholder, never as a literal in the Caddyfile. The plugins resolve the placeholder when they provision, so the config the admin API serves at `GET /config/` keeps the placeholder. A literal value comes back as written to anything that can reach that endpoint.

`CLOUDFLARE_API_TOKEN` is an API token with `Zone:Zone:Read` and `Zone:DNS:Edit` for the zones you serve, read by the `caddy-dns/cloudflare` plugin.

- A token the plugin rejects for its format is printed in full in the container log. Treat any value that appears in a startup or reload error as exposed and rotate it.
- The format check is anchored, so any extra character around the token fails it. Surrounding quotes or braces fail, and so do a stray space and a trailing newline read from a file. A good token can leak because of what surrounds it. Pass the bare token with nothing around it.
- The format check tests the shape of a value, not its permissions. A value of the right shape that is not a valid token passes it and fails only when Cloudflare receives the DNS-01 request. Use a scoped API token with `Zone:Zone:Read` and `Zone:DNS:Edit`. Do not use a [Global API Key](https://developers.cloudflare.com/fundamentals/api/get-started/keys/), which has every permission your Cloudflare user has.

`CROWDSEC_BOUNCER_KEY` is the bouncer API key that `cscli bouncers add caddy` prints, read by the `caddy-crowdsec-bouncer` plugin.

## Reloading the Caddyfile

Send the running process SIGUSR1 with `docker kill -s USR1 caddy`. Caddy reloads from the `--config` file and the `--adapter` that the image's command already records. A deploy script that needs a rejected Caddyfile to show up in its own exit status can run `docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile` instead. Either way, a rejected Caddyfile leaves the previous config running.

Mount the folder that holds the Caddyfile, as the compose example does with `./caddy:/etc/caddy`, not the single file. A single-file bind mount pins one inode, so an editor that saves by renaming the file leaves the container reading the old bytes. That defeats every reload path. If you mount the single file anyway, save it in place.

The container has no shell. `docker exec` can run only `caddy` and `/probe`, so debugging otherwise goes through the logs, the metrics and the admin API.

## Watch mode

Watch mode is off by default. Caddy documents `--watch` as a feature for local development, so the image ships Caddy's own command. To turn it on, override the command on your compose service:

```yaml
command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile", "--watch"]
```

One save that fails to adapt stops the watcher for the life of the container. Later valid edits are then ignored, and no healthcheck and no metric reports it. The `watcher` logger writes `unable to load latest config` once, with the adapter error, at the moment it stops, and the `CaddyConfigWatcherStopped` rule in [Monitoring and alerts](monitoring.md) matches that line. Recovery is a container restart. An explicit reload applies the current file but does not start the watcher again.

Check a file before you save it with `docker exec caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile`.

## The admin API

Both example Caddyfiles state `admin localhost:2019`, which keeps Caddy's admin API on the container's loopback. That is also Caddy's documented default. The healthcheck probes this address, and stating it guards against a global options block that rebinds it by accident. The directive outranks the `CADDY_ADMIN` environment variable, which only supplies the default address Caddy uses when no `admin` directive sets one.

The image declares port 2019 for documentation and for scrapers that share the container's network namespace. Publishing it helps only when a Caddyfile deliberately moves `admin` off loopback, and then it is a control plane with no login on a routable address.

## The metrics listener

Port 2020 is a Caddyfile decision, not an image one. Nothing in the image opens it, and it is not in the image's `EXPOSE`. `Caddyfile.plugins.example` opens it with `:2020 { metrics /metrics }`, and `Caddyfile.example` does not. The compose example publishes no host port for it. A site address with no host binds every interface in the container, so any container on the same Docker network can read the series.
