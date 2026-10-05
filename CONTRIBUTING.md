# Contributing to docker-caddy

The [shared rules](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md) for commits, releases, synced files and checks apply here.

## Rules

Both example Caddyfiles must adapt with no warning and pass `caddy fmt`. With `--watch`, Caddy prints an adapter warning again once per second, so a warning is a defect.

## Checks

To iterate on `tests/smoke.sh` without a Docker build, run it against a local binary:

```sh
CADDY_BIN=./caddy sh tests/smoke.sh
```

Build that binary with `xcaddy` from the two plugin versions the Dockerfile pins and the Caddy release in its pinned builder image's `CADDY_VERSION`. A stock `caddy` fails the plugin checks, and another release can fail the certmagic check.

The script also needs `curl` on PATH and ports 80, 443, 2019, 2020, 2099 and 8082 free on loopback.
