# docker-caddy

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-caddy/badges/size.json)](https://github.com/cplieger/docker-caddy/pkgs/container/docker-caddy) [![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)](https://github.com/cplieger/docker-caddy/pkgs/container/docker-caddy) [![built from: caddy-builder](https://img.shields.io/badge/built%20from-caddy--builder-1F88C0?logo=caddy)](https://github.com/cplieger/docker-caddy/blob/main/Dockerfile) [![runtime: distroless/static](https://img.shields.io/badge/runtime-distroless%2Fstatic-blue)](https://github.com/cplieger/docker-caddy/blob/main/Dockerfile) [![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-caddy/releases)

<!-- hub-overview BEGIN -->
docker-caddy is the [Caddy](https://caddyserver.com/) web server and reverse proxy with plugins that get certificates through Cloudflare DNS and block the IP addresses CrowdSec bans. Everything else is standard Caddy, set up from your own Caddyfile.

## What it does

docker-caddy gets trusted certificates for your public and LAN-only sites and keeps known attackers out at the proxy:

- Gets certificates for wildcard and LAN-only sites through your Cloudflare DNS, so issuing one needs no open port.
- Blocks the IP addresses your CrowdSec instance bans before their requests reach your services.
- Ships alert rules for Prometheus and Loki that report failed certificates, rejected reloads and CrowdSec outages.
- Runs on a minimal base image with no shell or package manager, and checks its own health.

## Who it is for

docker-caddy is built for people who write their own Caddyfile, keep their domain's DNS on Cloudflare and run CrowdSec. It adds no other plugin and leaves out the CrowdSec plugin's AppSec request inspection.

You need a Cloudflare API token that can edit DNS for your zone. You also need a CrowdSec instance whose Local API the container can reach, and a key from `cscli bouncers add caddy`.

Two other projects suit a different setup:

- Consider [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) if you want Caddy configured from Docker container labels. It writes the Caddyfile from those labels and reloads when containers change.
- Consider [Nginx Proxy Manager](https://github.com/NginxProxyManager/nginx-proxy-manager) if you want to manage proxy hosts and certificates from a web admin page.

docker-caddy is free software under the Apache-2.0 license.
<!-- hub-overview END -->

## Quick start

The image is on GitHub Container Registry and Docker Hub, for `amd64` and `arm64`. This is the [`compose.yaml`](compose.yaml) in this repository.

```yaml
services:
  caddy:
    image: ghcr.io/cplieger/docker-caddy:latest
    container_name: caddy
    restart: unless-stopped

    environment:
      # Put both values in a .env file beside this one before the first start, and keep .env out of git.
      CLOUDFLARE_API_TOKEN: "${CLOUDFLARE_API_TOKEN:-}"  # Cloudflare API token for DNS-01 certificates
      CROWDSEC_BOUNCER_KEY: "${CROWDSEC_BOUNCER_KEY:-}"  # the key "cscli bouncers add caddy" prints

    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3

    volumes:
      # Before the first start, put your Caddyfile at ./caddy/Caddyfile. Mount the folder, not the file.
      - "./caddy:/etc/caddy:ro"
      - "./data:/data"  # certificates and ACME state, keep this folder
```

1. In the folder that holds `compose.yaml`, run `mkdir caddy`.
2. Save [`Caddyfile.plugins.example`](Caddyfile.plugins.example) from this repository as `caddy/Caddyfile`. It uses both plugins.
3. In `caddy/Caddyfile`, change the site address `*.example.com`, the `reverse_proxy` target and the `api_url` in the `crowdsec` block. The `api_url` is a CrowdSec LAPI address the container can reach. The shipped `http://crowdsec:8080` works only when a `crowdsec` container shares a Compose network with this one. When the bouncer cannot reach the LAPI, it lets every request through, so a wrong address blocks nothing. [When the LAPI is down](docs/plugins.md#when-the-lapi-is-down) shows how to make Caddy stop instead.
4. Create the API token on the API Tokens page of the Cloudflare dashboard, with `Zone:Zone:Read` and `Zone:DNS:Edit` for your zones.
5. Run `cscli bouncers add caddy` where CrowdSec runs, and keep the key it prints.
6. Create a file named `.env` beside `compose.yaml` with these two lines:

   ```sh
   CLOUDFLARE_API_TOKEN=your-cloudflare-api-token
   CROWDSEC_BOUNCER_KEY=your-crowdsec-bouncer-key
   ```

7. Run `docker compose up -d`.

Run `docker logs caddy`. You should see `serving initial configuration`. If you see `loading initial config` followed by an error, a value in `.env` is missing or wrong, or a port is already in use.

The [tags](https://github.com/cplieger/docs/blob/main/docs/images.md#which-tag-to-use) are `latest`, `vX`, `vX.Y` and `vX.Y.Z`. They count this image's releases and do not match Caddy's version numbers. Renovate updates Caddy and both plugins, and [What the image contains](docs/hardening.md#what-the-image-contains) lists every pinned dependency. To see the Caddy version a tag carries, run `docker run --rm ghcr.io/cplieger/docker-caddy:latest caddy version`. To see the plugin versions, run `docker run --rm ghcr.io/cplieger/docker-caddy:latest caddy list-modules --skip-standard --versions`.

## Configuration reference

Caddy reads every setting from your Caddyfile, at start and on each reload. Environment variables reach it only through `{env.VAR}` placeholders in the Caddyfile, and the two plugins read the variables below that way. `Caddyfile.plugins.example` needs both variables. `Caddyfile.example` uses neither plugin, so it needs neither variable. [Configuration](docs/configuration.md) covers reloads, watch mode, the admin API and the metrics listener.

| Variable | Description | Default |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with `Zone:Zone:Read` and `Zone:DNS:Edit` for your zones, read by `dns cloudflare`. Pass the bare token | _(unset)_ |
| `CROWDSEC_BOUNCER_KEY` | Bouncer key from `cscli bouncers add caddy`, read by the `crowdsec` global block | _(unset)_ |

| Mount | Description |
| --- | --- |
| `/etc/caddy` | The folder that holds your `Caddyfile`. Read-only is fine. Mount the folder, not the single file |
| `/data` | Issued certificates, ACME state and plugin storage. Keep it, or Caddy issues new certificates on every restart |
| `/config` | Optional. Caddy's saved copy of its running config and other persistent state |

| Port | Description |
| --- | --- |
| `80/tcp` | HTTP, ACME HTTP challenges and redirects to HTTPS |
| `443/tcp` | HTTPS and HTTP/2 |
| `443/udp` | HTTP/3 |
| `2019/tcp` | Caddy's admin API, with no login. It answers only inside the container |
| `2020/tcp` | Prometheus metrics, only when your Caddyfile opens this listener |

## Security

Publish only ports 80 and 443. Caddy's admin API on port 2019 has no login, and both example Caddyfiles keep it on the container's own loopback with `admin localhost:2019`. Keep it there. The metrics listener on port 2020 in `Caddyfile.plugins.example` answers any container on the same Docker network.

Write each credential in the Caddyfile as `{env.CLOUDFLARE_API_TOKEN}` or `{env.CROWDSEC_BOUNCER_KEY}`. The admin API returns a credential pasted into the Caddyfile to anything that can reach it. When the Cloudflare plugin rejects a token for its format, it prints the whole token in the container log. If a token appears in a startup or reload error, treat it as exposed and create a new one.

The container runs as root, like the official Caddy image, so it can bind ports 80 and 443. [Security](docs/hardening.md) covers running it as another user, what the image contains and how to verify its signature.

## Troubleshooting

The healthcheck asks Caddy's admin API for its config every 30 seconds. An unhealthy container means the admin API stopped answering, most often a hung reload while your sites keep serving. [Admin API stall](docs/monitoring.md#admin-api-stall) shows how to find the stuck reload. With `admin off` or another admin address in your Caddyfile, the check fails while your sites serve. It does not test your sites, and [Troubleshooting](docs/troubleshooting.md) shows how to probe them.

When Caddy cannot start, the container exits with status 1 and restarts.

- The container restarts with no error in the log. The Caddyfile is missing, unreadable or does not parse, and Caddy prints nothing ([caddyserver/caddy#7962](https://github.com/caddyserver/caddy/issues/7962)). Run `docker compose run --rm caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` to see the cause.
- The log shows `loading initial config`. A plugin refused its credential, or a port is in use. Check `.env` first.
- A Caddyfile edit changes nothing. Run `docker kill -s USR1 caddy` to reload it. An editor that saves by renaming the file needs the folder mounted.
- CrowdSec blocks nothing. ERROR lines from the `crowdsec` logger mean the bouncer cannot reach the LAPI at `api_url`. Otherwise, check that the site block has the `crowdsec` directive and that CrowdSec bans the address. Behind Cloudflare's proxy, set [`trusted_proxies`](docs/plugins.md#behind-another-proxy) so the bouncer sees visitor addresses.

## Monitoring

Caddy serves Prometheus metrics from its admin API and from the `:2020` listener in `Caddyfile.plugins.example`, and writes JSON logs. Seven PromQL rules ship in [`alerts/promql.yaml`](alerts/promql.yaml) and five LogQL rules in [`alerts/logql.yaml`](alerts/logql.yaml). Load both, because the log rules cover failures Caddy's metrics cannot see. [Monitoring and alerts](docs/monitoring.md) lists them and what each one needs. It also shows where to load each file and which pairs of rules report the same fault.

## Documentation

- [Configuration](docs/configuration.md) covers credentials, reloads, watch mode, the admin API and the metrics listener.
- [Plugins](docs/plugins.md) explains both plugins and how the bouncer behaves when CrowdSec is down.
- [Troubleshooting](docs/troubleshooting.md) covers the healthcheck in depth, an end-to-end health probe and quieter admin logs.
- [Monitoring and alerts](docs/monitoring.md) lists the alert rules, their prerequisites and what tells you Caddy stopped.
- [Security](docs/hardening.md) covers running as another user, what the image contains and signature checks.
- [How docker-caddy is built](docs/how-it-works.md) is for readers who want the build design.

## Credits

docker-caddy packages [Caddy](https://github.com/caddyserver/caddy) by [@mholt](https://github.com/mholt) and the Caddy community, and all credit for the server goes to them. It is built with [xcaddy](https://github.com/caddyserver/xcaddy) from the [official Caddy image](https://hub.docker.com/_/caddy), which also supplies the default Caddyfile, welcome page and state folders. The plugins are [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) and [caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) by [@hslatman](https://github.com/hslatman). The healthcheck binary comes from [health](https://github.com/cplieger/go/tree/main/health), by the same author as this image.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI assistance. The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE). The image carries the license text of every bundled component under `/usr/share/licenses/`.

The image packages [Caddy](https://caddyserver.com/) (Apache-2.0, source at <https://github.com/caddyserver/caddy>), built with `xcaddy` from the official `caddy:2.11-builder` image the Dockerfile pins by digest, together with the [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) and [caddy-crowdsec-bouncer](https://github.com/hslatman/caddy-crowdsec-bouncer) plugins (both Apache-2.0) at the versions the Dockerfile's `--with` flags name. The build applies no patches. One linked module, [hslatman/ipstore](https://github.com/hslatman/ipstore), publishes no license file and carries the Apache-2.0 header in every source file; the packager supplies its license text under `licenses/` in this repository, and it ships in the image beside the others.
