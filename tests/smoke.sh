#!/bin/sh
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
caddy="${CADDY_BIN:-caddy}"
fail=0
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

if ! out=$("$caddy" version 2>&1); then
  err "FAIL: 'caddy version' did not run"
  err "$out"
  fail=1
fi

if ! mods=$("$caddy" list-modules 2>&1); then
  err "FAIL: 'caddy list-modules' did not run"
  err "$mods"
  fail=1
else
  if ! printf '%s\n' "$mods" | grep -qE '^dns\.providers\.cloudflare[[:space:]]*$'; then
    err "FAIL: dns.providers.cloudflare module is not compiled into the binary"
    fail=1
  fi
  if ! printf '%s\n' "$mods" | grep -qE '^http\.handlers\.crowdsec[[:space:]]*$'; then
    err "FAIL: http.handlers.crowdsec module is not compiled into the binary"
    fail=1
  fi
fi

# The test stage copies examples beside this script; local runs use the repo root.
example="$d/Caddyfile.example"
[ -f "$example" ] || example="$d/../Caddyfile.example"
if ! out=$("$caddy" validate --adapter caddyfile --config "$example" 2>&1); then
  err "FAIL: 'caddy validate' rejected Caddyfile.example"
  err "$out"
  fail=1
fi

# Reject a malformed config so validation cannot become vacuous.
bad=$(mktemp)
trap 'rm -f "$bad"' EXIT
printf '%s\n' ':80 {' >"$bad"
if "$caddy" validate --adapter caddyfile --config "$bad" >/dev/null 2>&1; then
  err "FAIL: 'caddy validate' accepted a malformed Caddyfile (vacuous gate?)"
  fail=1
fi

# Validate plugin directives with dummy credentials, never caller secrets.
plugins="$d/Caddyfile.plugins.example"
[ -f "$plugins" ] || plugins="$d/../Caddyfile.plugins.example"
cf_token=$(printf 'cfut_%032d' 0)
cs_key=smoke-not-a-real-key
if ! out=$(CLOUDFLARE_API_TOKEN="$cf_token" CROWDSEC_BOUNCER_KEY="$cs_key" \
  "$caddy" validate --adapter caddyfile --config "$plugins" 2>&1); then
  err "FAIL: 'caddy validate' rejected Caddyfile.plugins.example"
  err "$out"
  fail=1
fi
# Empty credentials keep the plugin success check non-vacuous.
# Keep empty assignments last; gitleaks treats a following variable as a secret value.
if CROWDSEC_BOUNCER_KEY="$cs_key" CLOUDFLARE_API_TOKEN='' \
  "$caddy" validate --adapter caddyfile --config "$plugins" >/dev/null 2>&1; then
  err "FAIL: Caddyfile.plugins.example validated with an empty CLOUDFLARE_API_TOKEN"
  fail=1
fi
if CLOUDFLARE_API_TOKEN="$cf_token" CROWDSEC_BOUNCER_KEY='' \
  "$caddy" validate --adapter caddyfile --config "$plugins" >/dev/null 2>&1; then
  err "FAIL: Caddyfile.plugins.example validated with an empty CROWDSEC_BOUNCER_KEY"
  fail=1
fi

# caddy validate permits formatting warnings.
for cfg in "$example" "$plugins"; do
  if ! out=$("$caddy" fmt --diff "$cfg" 2>&1); then
    err "FAIL: 'caddy fmt --diff' reports $cfg is not formatted"
    err "$out"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && log "caddy smoke: ok"
exit "$fail"
