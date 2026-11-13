#!/usr/bin/env bash
# CI executes this opt-in runner. tests/smoke.sh covers the image and the rule
# selectors, so this suite covers what only a reader of the docs would otherwise
# check: the Alertmanager example docs/monitoring.md shows.
set -u

cd -- "$(dirname -- "$0")" || exit 1

failed=0
ran=0
# Each test runs in its own process so stubs, traps and options cannot leak.
for t in ./*_test.sh; do
  if [ ! -f "$t" ]; then
    printf 'harness error: no *_test.sh found in %s\n' "$PWD" >&2
    exit 1
  fi
  printf '=== %s\n' "$(basename "$t")"
  ran=$((ran + 1))
  bash "$t" || failed=$((failed + 1))
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf 'FAILED: %d of %d test files failed\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d test files passed\n' "$ran"
