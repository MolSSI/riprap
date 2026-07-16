#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

render_project() {
  local language="$1" destination="$2"
  local skeleton_key="include_${language}_skeleton"
  copier copy --trust --defaults \
    --data project_name="Guardrails ${language} Test" \
    --data project_slug="guardrails-${language}-test" \
    --data project_description='Exercises the Guardrails development container' \
    --data language="$language" \
    --data "$skeleton_key=false" \
    --data author_name='Guardrails Tests' \
    --data author_email='guardrails@example.com' \
    --data open_source_license='Not Open Source' \
    "$ROOT" "$destination"
}

assert_copier_in_container() (
  local language="$1"
  local temp project image version major
  temp="$(mktemp -d)"
  image="guardrails-copier-test-$language"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"

  render_project "$language" "$project"
  podman build --tag "$image" "$project/.guardrails/podman"
  version="$(podman run --rm "$image" copier --version)"
  major="$(printf '%s\n' "$version" | grep -Eo '[0-9]+' | head -n 1)"
  test "$major" = 9 || fail "expected Copier major 9 in $language image, got: $version"
)

# rq-a32974ac
test_copier_in_rust_container() {
  assert_copier_in_container rust
}

# rq-876d30dd
test_copier_in_python_container() {
  assert_copier_in_container python
}

test_copier_in_rust_container
test_copier_in_python_container
printf 'PASS: generated development containers include Copier\n'
