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
log() { printf '%s\n' "$*"; }     # final verdict -> stdout
err() { printf '%s\n' "$*" >&2; } # failures + captured output -> stderr

# 1. The binary runs.
if ! out=$("$caddy" version 2>&1); then
  err "FAIL: 'caddy version' did not run"
  err "$out"
  fail=1
fi

# 2. Both bundled plugins are actually compiled in (the xcaddy failure mode).
mods_listed=1
if ! mods=$("$caddy" list-modules 2>&1); then
  err "FAIL: 'caddy list-modules' did not run"
  err "$mods"
  fail=1
  mods_listed=0
  mods=""
fi
if [ "$mods_listed" -eq 1 ]; then
  if ! printf '%s\n' "$mods" | grep -qE '^dns\.providers\.cloudflare[[:space:]]*$'; then
    err "FAIL: dns.providers.cloudflare module is not compiled into the binary"
    fail=1
  fi
  if ! printf '%s\n' "$mods" | grep -qE '^http\.handlers\.crowdsec[[:space:]]*$'; then
    err "FAIL: http.handlers.crowdsec module is not compiled into the binary"
    fail=1
  fi
fi

# 3. The shipped example Caddyfile validates against this build.
# In the Docker test stage Caddyfile.example is copied beside this script
# (into tests/); for a local `sh tests/smoke.sh` run it lives at the repo root.
example="$d/Caddyfile.example"
[ -f "$example" ] || example="$d/../Caddyfile.example"
if ! out=$("$caddy" validate --adapter caddyfile --config "$example" 2>&1); then
  err "FAIL: 'caddy validate' rejected Caddyfile.example"
  err "$out"
  fail=1
fi

# 4. Negative control: a malformed Caddyfile MUST be rejected. Step 3 only
#    proves 'caddy validate' accepts a good config; on its own that goes vacuous
#    if validate ever no-ops or exits 0 without parsing. Asserting a non-zero
#    exit on a broken config keeps the gate live and is wording-independent (it
#    checks the exit code, not a specific adapter error string). An unclosed
#    site block is a pure syntax error no caddy version can accept.
bad=$(mktemp)
trap 'rm -f "$bad"' EXIT
printf '%s\n' ':80 {' >"$bad"
if "$caddy" validate --adapter caddyfile --config "$bad" >/dev/null 2>&1; then
  err "FAIL: 'caddy validate' accepted a malformed Caddyfile (vacuous gate?)"
  fail=1
fi

[ "$fail" -eq 0 ] && log "caddy smoke: ok"
exit "$fail"
