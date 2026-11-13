#!/usr/bin/env bash
# The inhibit_rules example in docs/monitoring.md is checked here: amtool must
# accept it, and a live Alertmanager loaded with it must mute CaddyReloadRejected
# while CaddyConfigReloadFailed fires, which a syntax check alone cannot show.
# ALERTMANAGER and AMTOOL name local binaries; without them the pinned image runs.
#
# SC2015: `cond && ok || no` cannot mis-fire, because lib.sh's ok/no return 0.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

page=$REPO_ROOT/docs/monitoring.md
# Alertmanager v0.34.1 fixed inhibitions that un-muted their targets, so keep
# the pin at or above it.
image=prom/alertmanager:v0.34.2@sha256:39d8bb3966c694a124428a3a88fbcffd40bd069129ecd47c059f8a3f17c55f3b
port=${ALERTMANAGER_TEST_PORT:-19093}
heading='### Rules that report the same fault'
cfg=$WORK/alertmanager.yml
container=caddy-inhibit-test-$$
am_pid=

run_amtool() {
  if [ -n "${AMTOOL:-}" ]; then
    "$AMTOOL" "$@"
  else
    docker run --rm --network none --entrypoint amtool -v "$WORK:/cfg:ro" "$image" "$@"
  fi
}

stop_alertmanager() {
  if [ -n "$am_pid" ]; then
    kill "$am_pid" 2>/dev/null
    wait "$am_pid" 2>/dev/null
  elif [ -z "${ALERTMANAGER:-}" ]; then
    docker rm -f "$container" >/dev/null 2>&1
  fi
  return 0
}

awk -v want="$heading" '
  /^#+ / { in_section = ($0 == want); next }
  in_section && !done && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { in_block = 0; done = 1; next }
  in_block { print }
' "$page" >"$WORK/example.yaml"

if [ ! -s "$WORK/example.yaml" ]; then
  no "example extraction" "docs/monitoring.md has no yaml block under \"$heading\""
  report
  exit
fi
ok "docs/monitoring.md shows a yaml example under \"$heading\""

grep -q '^inhibit_rules:' "$WORK/example.yaml" \
  && ok "the example is an inhibit_rules block" \
  || no "inhibit_rules block" "the example does not start an inhibit_rules key"

# The example is the fragment a reader pastes into an existing config, so the
# test supplies the one route and receiver every config needs.
{
  printf '%s\n' 'route:' '  receiver: discard' 'receivers:' '  - name: discard'
  cat "$WORK/example.yaml"
} >"$cfg"
# The image runs as an unprivileged user, which must read the config.
chmod 755 "$WORK"
chmod 644 "$cfg"

if [ -z "${AMTOOL:-}" ] && ! command -v docker >/dev/null 2>&1; then
  no "Alertmanager" "set AMTOOL and ALERTMANAGER to local binaries, or install Docker to run $image"
  report
  exit
fi
if [ -z "${AMTOOL:-}" ] || [ -z "${ALERTMANAGER:-}" ]; then
  # Three pulls, so one registry timeout on a shared runner does not fail the check.
  for attempt in 1 2 3; do
    docker pull -q "$image" >/dev/null && break
    sleep $((attempt * 5))
  done
fi

if [ -n "${AMTOOL:-}" ]; then
  run_amtool check-config "$cfg" >"$WORK/amtool.out" 2>&1
else
  run_amtool check-config /cfg/alertmanager.yml >"$WORK/amtool.out" 2>&1
fi
rc=$?
[ "$rc" -eq 0 ] \
  && ok "amtool check-config accepts the example" \
  || no "amtool check-config" "rc=$rc: $(cat "$WORK/amtool.out")"

if [ -n "${ALERTMANAGER:-}" ]; then
  "$ALERTMANAGER" --config.file="$cfg" --storage.path="$WORK/data" \
    --web.listen-address="127.0.0.1:$port" --cluster.listen-address= \
    >"$WORK/alertmanager.log" 2>&1 &
  am_pid=$!
else
  docker run -d --rm --name "$container" -p "127.0.0.1:$port:9093" \
    -v "$WORK:/cfg:ro" "$image" --config.file=/cfg/alertmanager.yml \
    --storage.path=/tmp/alertmanager --cluster.listen-address= >/dev/null
fi

base=http://127.0.0.1:$port
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$base/-/ready" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  no "Alertmanager start" "not ready on $base after 30s"
  stop_alertmanager
  report
  exit
fi
ok "Alertmanager loaded with the example is ready"

# Each alert carries the labels its own ruler gives it: the metric rule the
# scrape's job and instance, the log rules the collector's container.
cat >"$WORK/alerts.json" <<'EOF'
[
  {"labels": {"alertname": "CaddyConfigReloadFailed", "severity": "critical", "job": "caddy", "instance": "caddy:2020"}},
  {"labels": {"alertname": "CaddyReloadRejected", "severity": "critical", "container": "caddy"}},
  {"labels": {"alertname": "CaddyConfigWatcherStopped", "severity": "critical", "container": "caddy"}}
]
EOF
if ! curl -fsS -X POST -H 'Content-Type: application/json' \
  --data @"$WORK/alerts.json" "$base/api/v2/alerts" >"$WORK/post.out" 2>&1; then
  no "posting the alerts" "$(cat "$WORK/post.out")"
  stop_alertmanager
  report
  exit
fi
curl -fsS "$base/api/v2/alerts" >"$WORK/alerts.out" 2>&1
stop_alertmanager

field() {
  jq -r --arg a "$1" ".[] | select(.labels.alertname == \$a) | $2" "$WORK/alerts.out"
}
source_fp=$(field CaddyConfigReloadFailed .fingerprint)
if [ -z "$source_fp" ]; then
  no "reading the alerts" "no CaddyConfigReloadFailed in $(cat "$WORK/alerts.out")"
  report
  exit
fi

field CaddyReloadRejected '.status.inhibitedBy[]' | grep -qxF "$source_fp" \
  && ok "CaddyReloadRejected lists CaddyConfigReloadFailed in status.inhibitedBy" \
  || no "inhibition" "CaddyReloadRejected inhibitedBy is $(field CaddyReloadRejected '.status.inhibitedBy')"
[ "$(field CaddyReloadRejected .status.state)" = suppressed ] \
  && ok "CaddyReloadRejected is suppressed" \
  || no "suppressed target" "CaddyReloadRejected state is $(field CaddyReloadRejected .status.state)"
[ "$(field CaddyConfigReloadFailed .status.state)" = active ] \
  && ok "CaddyConfigReloadFailed still notifies" \
  || no "active source" "CaddyConfigReloadFailed state is $(field CaddyConfigReloadFailed .status.state)"
[ "$(field CaddyConfigWatcherStopped .status.state)" = active ] \
  && ok "the inhibition mutes no other Caddy alert" \
  || no "unrelated alert" "CaddyConfigWatcherStopped state is $(field CaddyConfigWatcherStopped .status.state)"

report
