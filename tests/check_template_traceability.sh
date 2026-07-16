#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# rq-f63c0743 rq-cb2cdd8e
validate_template_ids() {
  local matches
  matches=$(rg -n 'rq-[0-9a-f]{8}' "$ROOT/template" || true)
  if [[ -n "$matches" ]]; then
    printf 'Concrete requirement IDs are forbidden in the template tree:\n%s\n' "$matches" >&2
    return 1
  fi
}

# rq-70d8296b
validate_registry_boundary() {
  if [[ -f "$ROOT/rqm/registry.json" ]] && rg -n '"path"[[:space:]]*:[[:space:]]*"template/' "$ROOT/rqm/registry.json"; then
    printf 'Guardrails registry must not index template source paths.\n' >&2
    return 1
  fi
}

validate_template_ids
validate_registry_boundary
