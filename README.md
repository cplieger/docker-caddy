# docker-caddy

[Caddy](https://caddyserver.com/) built with [`xcaddy`](https://github.com/caddyserver/xcaddy)
and the following plugins:

- [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare) — Cloudflare DNS-01 ACME challenge
- [`hslatman/caddy-crowdsec-bouncer`](https://github.com/hslatman/caddy-crowdsec-bouncer) — CrowdSec bouncer

## Image

```
ghcr.io/cplieger/docker-caddy
```

Multi-arch, signed (cosign) and SBOM-attested via the shared
[`cplieger/ci`](https://github.com/cplieger/ci) workflows.

## Usage

See [`compose.yaml`](./compose.yaml). Mount your `Caddyfile` at
`/etc/caddy/Caddyfile`.
