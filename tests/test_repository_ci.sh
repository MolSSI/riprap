#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/test.yaml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

event_block() {
  local event="$1"
  awk -v event="$event" '
    $0 == "  " event ":" { active = 1; print; next }
    active && /^  [[:alnum:]_-]+:/ { exit }
    active && /^[^[:space:]]/ { exit }
    active { print }
  ' "$WORKFLOW"
}

# rq-b4c43b87
test_every_pull_request_runs_ci() {
  local block
  block="$(event_block pull_request)"
  [[ "$block" == "  pull_request:" ]] ||
    fail 'pull_request trigger has filters, so it does not cover every base branch'
}

# rq-0da67b01
test_main_push_runs_ci() {
  local block
  block="$(event_block push)"
  grep -Eq '^[[:space:]]+- main$' <<<"$block" ||
    fail 'push trigger does not include main'
}

# rq-f5edc2ae
test_other_pushes_do_not_run_ci() {
  local block branches
  block="$(event_block push)"
  branches="$(grep -E '^[[:space:]]+- ' <<<"$block" | sed -E 's/^[[:space:]]+-[[:space:]]+//')"
  [[ "$branches" == main ]] ||
    fail 'push trigger includes a branch or tag other than main'
}

test_every_pull_request_runs_ci
test_main_push_runs_ci
test_other_pushes_do_not_run_ci
printf 'PASS: repository CI event policy\n'
