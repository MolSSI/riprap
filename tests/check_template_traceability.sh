#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
REGISTRY="$ROOT/rqm/registry.json"

# An identifier belongs to Riprap only when the requirements registry records it.
# Template documentation and the requirements tooling's own fixtures legitimately contain
# illustrative identifiers, which are not Riprap identifiers and are not violations.
#
# grep is used rather than a search tool that skips hidden files by default: most template
# content lives under hidden directories such as "template/.riprap", and skipping them
# would leave this check scanning almost nothing.
# rq-f63c0743 rq-59ada47d rq-cb2cdd8e
validate_template_ids() {
  local identifiers matches
  [[ -f "$REGISTRY" && -d "$ROOT/template" ]] || return 0

  identifiers="$(grep -oE 'rq-[0-9a-f]{8}' "$REGISTRY" | sort -u)"
  # An empty pattern list would otherwise be read as one empty pattern, which matches
  # every line of every file.
  [[ -n "$identifiers" ]] || return 0

  matches="$(grep -rFn -f <(printf '%s\n' "$identifiers") "$ROOT/template" || true)"
  if [[ -n "$matches" ]]; then
    printf 'Riprap requirement IDs are forbidden in the template tree:\n%s\n' "$matches" >&2
    return 1
  fi
}

# rq-70d8296b
validate_registry_boundary() {
  if [[ -f "$REGISTRY" ]] && grep -nE '"path"[[:space:]]*:[[:space:]]*"template/' "$REGISTRY"; then
    printf 'Riprap registry must not index template source paths.\n' >&2
    return 1
  fi
}

validate_template_ids
validate_registry_boundary
