#!/bin/sh
# Build-time smoke test for docker-caddy.
#
# Runs in the Dockerfile `test` stage (FROM builder), so the central `ci / validate`
# docker gate executes it on every PR and push -- the final stage depends on this
# stage's /tests-passed marker. Asserts the real failure mode for a custom xcaddy
# build: a plugin silently dropping out of the binary.
#
# Run locally:  sh tests/smoke.sh   (needs `caddy` on PATH; override CADDY_BIN)
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

# Reject an unformatted config so the formatting check cannot become vacuous.
unformatted=$(mktemp)
trap 'rm -f "$bad" "$unformatted"' EXIT
printf '%s\n' ':80 {' 'respond 200' '}' >"$unformatted"
if "$caddy" fmt --diff "$unformatted" >/dev/null 2>&1; then
  err "FAIL: 'caddy fmt --diff' accepted an unformatted Caddyfile (vacuous gate?)"
  fail=1
fi

if ! (
  route_dir=$(mktemp -d)
  trap 'rm -rf "$route_dir"' EXIT
  route_log="$route_dir/caddy.log"
  extended="$route_dir/Caddyfile.extended"
  ordered="$route_dir/Caddyfile.ordered"
  route_fail=0

  start_route_config() {
    route_cfg=$1
    : >"$route_log"
    if ! "$caddy" start --adapter caddyfile --config "$route_cfg" \
      >"$route_log" 2>&1; then
      err "FAIL: caddy did not start with $route_cfg"
      cat "$route_log" >&2
      route_fail=1
      return 1
    fi
  }

  assert_route_status() {
    route_url=$1
    route_want=$2
    if ! route_got=$(curl -sS -o /dev/null -w '%{http_code}' "$route_url"); then
      err "FAIL: request to $route_url did not complete"
      route_fail=1
    elif [ "$route_got" != "$route_want" ]; then
      err "FAIL: $route_url returned $route_got, want $route_want"
      route_fail=1
    fi
  }

  stop_route_config() {
    if ! "$caddy" stop >/dev/null 2>&1; then
      err "FAIL: caddy did not stop after route smoke test"
      cat "$route_log" >&2
      route_fail=1
    fi
  }

  # Pin the UNDRIVEN example to the driven one. Caddyfile.plugins.example is
  # deliberately never started (its `*.example.com` block enters the TLS app's
  # automation set), so the only cheap detector for "its health or fallback
  # response changed" is that its `http://:80` block is byte-identical to the one
  # part B does drive -- an invariant both example files are maintained under.
  # Asserted non-empty first, so a stopped awk match cannot pass as agreement.
  block_of() {
    awk '/^http:\/\/:80 \{$/ { p = 1 } p { print } p && /^\}$/ { exit }' "$1"
  }
  block_of "$example" >"$route_dir/block-example"
  block_of "$plugins" >"$route_dir/block-plugins"
  if [ ! -s "$route_dir/block-example" ] || [ ! -s "$route_dir/block-plugins" ]; then
    err "FAIL: could not extract an http://:80 block from both examples (vacuous control?)"
    route_fail=1
  elif ! cmp -s "$route_dir/block-example" "$route_dir/block-plugins"; then
    err "FAIL: the examples' http://:80 blocks have diverged; the undriven plugins example is pinned to the driven one"
    diff "$route_dir/block-example" "$route_dir/block-plugins" >&2 || true
    route_fail=1
  fi

  if start_route_config "$example"; then
    assert_route_status http://127.0.0.1:80/health 200
    assert_route_status http://127.0.0.1:80/unmatched 404
    stop_route_config
  fi

  # The documented extension shape, tested with a directive the trap can reach:
  # `metrics` sorts AFTER `respond`, so its own site block is the remedy the
  # examples' warning prescribes. A `respond` here would pass whether or not the
  # published ordering claim held.
  cp "$example" "$extended"
  printf '\nhttp://:8081 {\n\tmetrics /metrics\n}\n' >>"$extended"
  if start_route_config "$extended"; then
    assert_route_status http://127.0.0.1:8081/metrics 200
    stop_route_config
  fi

  # Negative control, and the only assertion that pins the claim both examples
  # publish: the SAME directive, with a matcher, INSIDE the http://:80 block is
  # still outranked by the matcherless `respond 404`, because Caddy orders by
  # DIRECTIVE and not by line.
  awk '/^http:\/\/:80 \{$/ { print; print "\tmetrics /metrics"; next } { print }' \
    "$example" >"$ordered"
  if ! grep -qF 'metrics /metrics' "$ordered"; then
    err "FAIL: could not add a handler directive to the example's http://:80 block (vacuous control?)"
    route_fail=1
  elif start_route_config "$ordered"; then
    assert_route_status http://127.0.0.1:80/metrics 404
    stop_route_config
  fi

  exit "$route_fail"
); then
  fail=1
fi

if ! (
  signal_dir=$(mktemp -d)
  trap 'rm -rf "$signal_dir"' EXIT
  signal_cfg="$signal_dir/Caddyfile"
  signal_log="$signal_dir/caddy.log"
  signal_metrics="$signal_dir/metrics"
  # Same idiom as $example above: the build copies the bundle beside this script,
  # a local run reads the committed copy.
  signal_alerts="$d/alerts.yaml"
  [ -f "$signal_alerts" ] || signal_alerts="$d/../alerts.yaml"
  signal_fail=0

  # INVARIANT for anyone adding a pair below, and it has TWO arms because each one
  # has gone vacuous here already.
  #
  # ALERT ARM: the token is grepped -F in alerts.yaml, so it must be a substring of
  # the RULE EXPRESSION (or of the annotation that consumes the label) and unique to
  # it. A bare label name is satisfied by the file's own prose -- `handler` by the
  # header, `code` by "encoder", `upstream` by an annotation -- so aggregating the
  # label out of the expression would leave a bare-word gate green.
  #
  # RUNTIME ARM: the token must appear in the series of the METRIC the rule reads,
  # not anywhere in the exposition. Caddy registers
  # `caddy_admin_http_requests_total{handler,path,code,method}` unconditionally into
  # the registry the admin endpoint serves, and this block scrapes that endpoint, so
  # a bare `handler=`, `code=` or `method=` against the whole scrape is satisfied
  # even if every series the 5xx rule reads disappears. Bind the label to its metric.
  require_alert_runtime() {
    alert_token=$1
    runtime_token=$2
    runtime_file=$3
    if ! grep -qF "$alert_token" "$signal_alerts"; then
      err "FAIL: alerts.yaml no longer selects $alert_token"
      signal_fail=1
    elif ! grep -qF "$runtime_token" "$runtime_file"; then
      err "FAIL: runtime output no longer contains $runtime_token selected by alerts.yaml"
      signal_fail=1
    fi
  }

  # CaddyHigh5xxRate is a ratio, so its two arms must carry the SAME aggregation or
  # vector matching drops every element and the rule goes silent instead of red.
  # Presence anywhere in the file cannot see a ONE-SIDED edit, so scope the grep to
  # the rule and assert the COUNT: the number of arms carrying an aggregation is the
  # property. The extraction is asserted non-empty first, because a rule rename would
  # otherwise turn every count into 0 == 0 for a token nobody selects.
  require_rule_arms() {
    arms_token=$1
    arms_want=$2
    arms_runtime=$3
    arms_got=$(grep -cF "$arms_token" "$signal_dir/rule-5xx")
    if [ "$arms_got" != "$arms_want" ]; then
      err "FAIL: CaddyHigh5xxRate carries '$arms_token' on $arms_got arm(s), want $arms_want"
      signal_fail=1
    elif ! grep -qF "$arms_runtime" "$signal_dir/duration-series"; then
      err "FAIL: caddy_http_request_duration_seconds series no longer carries $arms_runtime"
      signal_fail=1
    fi
  }

  awk '/^      - alert: CaddyHigh5xxRate$/ { r = 1 } r && /^        for:/ { exit } r { print }' \
    "$signal_alerts" >"$signal_dir/rule-5xx"
  if [ ! -s "$signal_dir/rule-5xx" ]; then
    err 'FAIL: could not extract the CaddyHigh5xxRate expression from alerts.yaml (renamed?)'
    signal_fail=1
  fi

  cat >"$signal_cfg" <<'EOF'
{
  admin localhost:2019
  order crowdsec first
  metrics
  crowdsec {
    api_url http://127.0.0.1:9
    api_key smoke-not-a-real-key
    enable_caddy_metrics
  }
}

http://:8082 {
  crowdsec
  reverse_proxy 127.0.0.1:9 {
    fail_duration 1s
  }
}
EOF

  : >"$signal_log"
  if ! "$caddy" start --watch --adapter caddyfile --config "$signal_cfg" >"$signal_log" 2>&1; then
    err "FAIL: caddy did not start for alert-signal smoke test"
    cat "$signal_log" >&2
    signal_fail=1
  else
    curl -sS http://127.0.0.1:8082/ >/dev/null 2>&1 || true
    signal_i=0
    while [ "$signal_i" -lt 10 ]; do
      if curl -fsS http://127.0.0.1:2019/metrics >"$signal_metrics" 2>/dev/null \
        && grep -qF 'crowdsec_bouncer_lapi_requests_total' "$signal_metrics" \
        && grep -qF '"logger":"crowdsec"' "$signal_log"; then
        break
      fi
      signal_i=$((signal_i + 1))
      sleep 1
    done

    # The series of the one metric the 5xx rule reads, extracted once. The full
    # metric name is asserted against the whole scrape two lines below, so an empty
    # file here cannot pass unnoticed.
    grep '^caddy_http_request_duration_seconds_count{' "$signal_metrics" \
      >"$signal_dir/duration-series" || true

    require_alert_runtime caddy_config_last_reload_successful caddy_config_last_reload_successful "$signal_metrics"
    require_alert_runtime 'caddy_reverse_proxy_upstreams_healthy == 0' caddy_reverse_proxy_upstreams_healthy "$signal_metrics"
    # This is a literal Prometheus template token, not a shell expansion.
    # shellcheck disable=SC2016
    require_alert_runtime '{{ $labels.upstream }}' 'upstream=' "$signal_metrics"
    require_alert_runtime caddy_http_request_duration_seconds_count caddy_http_request_duration_seconds_count "$signal_metrics"
    require_rule_arms 'sum without (server, handler, code, method, host)' 1 'handler='
    require_rule_arms 'code=~"5.."' 1 'code='
    require_rule_arms 'sum without (server, code, method)' 2 'method='
    require_rule_arms 'sum without (server, code, method)' 2 'server='
    require_alert_runtime 'crowdsec_bouncer_lapi_requests_failures_total{mode="stream"}' crowdsec_bouncer_lapi_requests_failures_total "$signal_metrics"
    require_alert_runtime 'crowdsec_bouncer_lapi_requests_total{mode="stream"}' crowdsec_bouncer_lapi_requests_total "$signal_metrics"
    require_alert_runtime 'logger="crowdsec"' '"logger":"crowdsec"' "$signal_log"
    require_alert_runtime 'level="error"' '"level":"error"' "$signal_log"

    if ! grep -qF 'tls\\.(obtain|renew)' "$signal_alerts"; then
      err 'FAIL: alerts.yaml no longer selects both certmagic failure loggers'
      signal_fail=1
    elif ! build_info=$("$caddy" build-info 2>&1); then
      err "FAIL: 'caddy build-info' did not run"
      err "$build_info"
      signal_fail=1
    elif ! printf '%s\n' "$build_info" \
      | grep -qE 'github.com/caddyserver/certmagic[[:space:]]+v0\.25\.3'; then
      err 'FAIL: certmagic moved from the reviewed v0.25.3 alert-signal contract'
      signal_fail=1
    fi

    printf '%s\n' ':8082 {' >"$signal_cfg"
    signal_i=0
    while [ "$signal_i" -lt 10 ] \
      && ! grep -qF 'unable to load latest config' "$signal_log"; do
      signal_i=$((signal_i + 1))
      sleep 1
    done
    require_alert_runtime 'unable to load latest config' 'unable to load latest config' "$signal_log"
    require_alert_runtime 'logger="watcher"' '"logger":"watcher"' "$signal_log"

    if ! "$caddy" stop >/dev/null 2>&1; then
      err 'FAIL: caddy did not stop after alert-signal smoke test'
      cat "$signal_log" >&2
      signal_fail=1
    fi
  fi

  exit "$signal_fail"
); then
  fail=1
fi

[ "$fail" -eq 0 ] && log "caddy smoke: ok"
exit "$fail"
