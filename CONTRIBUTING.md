# Contributing to docker-caddy

Caddy rebuilt with `xcaddy` so the Cloudflare DNS-01 plugin and the CrowdSec
HTTP bouncer are compiled in, shipped on a distroless runtime. This guide
covers what the
[org-wide defaults](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md)
do not: how the build is staged, the invariants the two smoke tests hold, and
how to run those tests locally.

## Layout

The Dockerfile is the program; this repo has no Go source of its own.

- `Dockerfile`: `builder` runs `xcaddy build` with the two plugins pinned by
  version; `test` runs `tests/smoke.sh` against that binary; `probe-builder`
  installs the `/probe` healthcheck binary; `donor` is the digest-pinned
  upstream `caddy` image whose default Caddyfile, welcome page, MIME table and
  state directories the final stage copies; `donor-contract` asserts the built
  binary and the donor report the same Caddy version. The final stage is
  `gcr.io/distroless/static`, runs `caddy` as PID 1 with upstream's CMD, and
  has no shell.
- `Caddyfile.example` and `Caddyfile.plugins.example`: the shipped examples.
  Both are validated by the build, so they cannot drift from what the image
  loads.
- `alerts/promql.yaml` and `alerts/logql.yaml`: the recommended alert rules the
  README summarizes.
- `tests/smoke.sh`: the build-time suite. `tests/image-smoke.conf`: the
  runtime suite's per-app half. `tests/image-smoke.sh`: the shared harness,
  synced from [`cplieger/ci`](https://github.com/cplieger/ci); never edit it
  here, a sync overwrites it.
- `compose.yaml`: the example the README's quick start embeds.

## Invariants

- The builder and the runtime donor carry independent digest pins, so Renovate
  moves them in separate PRs. `donor-contract` fails the build when the two
  name different Caddy versions; bump the lagging pin rather than relaxing the
  check.
- Both example Caddyfiles must adapt with no warning and pass `caddy fmt`. With
  `--watch` a warning is re-emitted once per second, so a warning is a defect.
- Every alert rule that matches an upstream log line or metric name is bound by
  `tests/smoke.sh`, which provokes the condition on the real binary and greps
  the bundle and the captured output for the same selector. Renaming a
  selector in `alerts/` without moving the assertion fails the build; a Caddy
  bump that renames the upstream string does too, which is the point.
- The container's exit status is `caddy`'s. A rejected Caddyfile exits 1 and
  prints an `Error:` line, and both suites assert exactly that; nothing may
  wrap the process in a way that would swallow it.

## Running checks locally

The build-time suite runs inside `docker build`:

```sh
docker build --target test .
```

To iterate on `tests/smoke.sh` without a build, it needs a caddy binary that
carries both plugins (`xcaddy build --with github.com/caddy-dns/cloudflare
--with github.com/hslatman/caddy-crowdsec-bouncer/http`) and `curl` on PATH,
and it binds ports 80, 2019, 2020, 2099 and 8082 on loopback:

```sh
CADDY_BIN=./caddy sh tests/smoke.sh
```

The runtime suite boots the assembled image, waits for its own healthcheck, and
then drives it through `smoke_verify` in `tests/image-smoke.conf`: it checks
the copied upstream contract (storage roots, MIME table, state directory
modes, image metadata against the donor), provisions the Cloudflare provider in
the shipped binary with two refused controls, serves an unbanned client and
refuses a banned one through the CrowdSec bouncer against a decision stream the
container serves to itself, and ends by starting the image's own CMD on a
Caddyfile naming a DNS provider this build does not carry, asserting the
container stops with exit status 1. Every container runs with `--network none`;
the host needs registry access once, to pull the digest-pinned donor image the
assembly check compares against.

```sh
docker build -t docker-caddy .
sh tests/image-smoke.sh docker-caddy
```

Lint the shell with `shellcheck -S info` and `shfmt -d -i 2 -ci -bn`
(`tests/image-smoke.conf` has no shebang, so pass `-s sh -e SC2034`), and the
Dockerfile with `hadolint`.

## Commits and PRs

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
parsed by git-cliff to generate release notes, so the subject becomes a
changelog line: `feat:` (Added), `fix:` (Fixed), `sec:` (Security),
`chore(deps):` (Dependencies). Edits under `alerts/` and to Markdown files do
not trigger a release. Open the PR against `main` and make sure `ci / validate`
is green before merging.

## Conduct and security

By participating you agree to the
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report vulnerabilities through the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md),
never in a public issue.
