#!/bin/sh
# Build-time smoke test for docker-caddy.
#
# Runs in the Dockerfile `test` stage (FROM the xcaddy builder), so the
# centralized `ci / validate` docker build-ability gate executes it on every
# PR and push. The real failure mode for a custom xcaddy build is a plugin
# silently dropping out of the binary, so this asserts both bundled plugins are
# compiled in and that the shipped example Caddyfile validates against the
# build.
#
# Run locally:  sh tests/smoke.sh   (needs the plugin-built caddy on PATH)
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
caddy="${CADDY_BIN:-caddy}"
fail=0
log() { printf '%s\n' "$*"; }

# 1. The binary runs.
if ! "$caddy" version > /dev/null 2>&1; then
  log "FAIL: 'caddy version' did not run"
  fail=1
fi

# 2. Both bundled plugins are actually compiled in (the xcaddy failure mode).
mods=$("$caddy" list-modules 2> /dev/null || true)
if ! printf '%s\n' "$mods" | grep -qi 'cloudflare'; then
  log "FAIL: caddy-dns/cloudflare module is not compiled into the binary"
  fail=1
fi
if ! printf '%s\n' "$mods" | grep -qi 'crowdsec'; then
  log "FAIL: caddy-crowdsec-bouncer module is not compiled into the binary"
  fail=1
fi

# 3. The shipped example Caddyfile validates against this build.
# In the Docker test stage Caddyfile.example is copied beside this script
# (into tests/); for a local `sh tests/smoke.sh` run it lives at the repo root.
example="$d/Caddyfile.example"
[ -f "$example" ] || example="$d/../Caddyfile.example"
if ! "$caddy" validate --adapter caddyfile --config "$example" > /dev/null 2>&1; then
  log "FAIL: 'caddy validate' rejected Caddyfile.example"
  fail=1
fi

[ "$fail" -eq 0 ] && log "caddy smoke: ok"
exit "$fail"
