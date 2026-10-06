# Security

This page covers running Caddy as a user other than root, what the image contains and how to verify a pull. It is for operators hardening a deployment. What to expose and how to handle the two credentials are in the README's Security section and in [Configuration](configuration.md).

## Running as another user

The image runs as root by default, like the official Caddy image, so root binds ports 80 and 443 directly and the example needs no extra capability for them.

To run Caddy as a non-root user instead:

- Set `user: "<uid>:<gid>"` on the service.
- Run `chown` on the `/data` host folder for that UID, because Caddy writes certificates and ACME state there.
- If you mount `/config`, run `chown` on that host folder too. Caddy saves a copy of each config it loads under `/config/caddy`, and the image's own `/config/caddy` is writable by every user only while `/config` stays unmounted.

When that save fails, Caddy keeps serving and logs `unable to autosave config` at ERROR. It logs `unable to create folder for config autosave` instead when it cannot create `/config/caddy` at all. Caddy tries the save on every config it loads, so a wrong owner gives one line at startup and one more on every reload. The saved copy is also what `--resume` reads, so `--resume` then has nothing to resume.

Under Docker's defaults that is all. Containers start with `net.ipv4.ip_unprivileged_port_start=0`, so a process that is not root binds 80 and 443 directly. `cap_add: [NET_BIND_SERVICE]` does not help a non-root user here, because Docker grants added capabilities to root and the binary carries no file capability. If your Docker daemon hardens `ip_unprivileged_port_start`, restore it for this container with `sysctls: ["net.ipv4.ip_unprivileged_port_start=0"]`.

## What the image contains

The runtime is `gcr.io/distroless/static`, built on Debian. It has no shell and no package manager. It carries a few Debian data packages, such as time zone data and CA certificates. Image scans report fixes for those, and they arrive when Renovate updates the base image digest.

Two CVEs in indirect Go modules still show up in scans, `CVE-2026-44982` in CrowdSec and `CVE-2026-2303` in mongo-driver. Neither is reachable in this build. The bundled bouncer links only CrowdSec's LAPI client, so the vulnerable AppSec body parser and the MongoDB GSSAPI bindings are never compiled in. They clear once the bouncer plugin supports CrowdSec 1.7.8 or later.

[Renovate](https://github.com/renovatebot/renovate) updates every dependency below, each pinned by digest or version.

| Dependency | Source |
| --- | --- |
| caddy builder image, which compiles the binary | [Docker Hub](https://hub.docker.com/_/caddy) |
| caddy runtime image, which supplies the default Caddyfile, welcome page, MIME table and state folders | [Docker Hub](https://hub.docker.com/_/caddy) |
| distroless/static, the runtime base | [gcr.io/distroless](https://github.com/GoogleContainerTools/distroless) |
| caddy-dns/cloudflare | [GitHub](https://github.com/caddy-dns/cloudflare) |
| caddy-crowdsec-bouncer | [GitHub](https://github.com/hslatman/caddy-crowdsec-bouncer) |
| health, the probe binary | [GitHub](https://github.com/cplieger/health) |

The license text of every bundled component is in the image under `/usr/share/licenses/`.

## Verifying a pull

The image is signed with cosign and carries a signed software bill of materials. [Checking a signature](https://github.com/cplieger/docs/blob/main/docs/images.md#checking-a-signature) and [Reading the software bill of materials](https://github.com/cplieger/docs/blob/main/docs/images.md#reading-the-software-bill-of-materials) show how to check both, with `docker-caddy` as the app name.
