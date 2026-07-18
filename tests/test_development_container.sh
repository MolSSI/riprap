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

build_key() {
  sed -n "s/^$2=//p" "$1/.guardrails/podman/agent-build.candidate.env" | tr -d '\r' | head -n 1
}

# The launcher normally writes the build key; container tests build the image directly,
# so they write the key themselves to control which releases the image installs.
write_build_key() {
  printf 'CLAUDE_VERSION=%s\nCODEX_VERSION=%s\nREFRESH=%s\n' "$2" "$3" "$4" \
    > "$1/.guardrails/podman/agent-build.candidate.env"
}

# Builds one image from a rendered project and runs every named assertion against it,
# so the agent downloads happen once rather than once per assertion.
with_built_image() (
  local language="$1"; shift
  local temp project image assertion
  temp="$(mktemp -d)"
  image="guardrails-agent-test-$language-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project "$language" "$project"
  # Exact releases rather than "latest", so the recorded value can be compared against
  # what the built image reports.
  write_build_key "$project" 2.1.205 0.144.6 pinned
  podman build --tag guardrails-tooling:latest "$project/.guardrails/podman"
  podman build -f "$project/.guardrails/podman/Agent.Containerfile" --tag guardrails-agent:candidate "$project/.guardrails/podman"
  podman build -f "$project/.guardrails/podman/AgentLabels.Containerfile" \
    --build-arg CLAUDE_VERSION=2.1.205 --build-arg CODEX_VERSION=0.144.6 \
    --build-arg TOOLING_IMAGE_ID=test-tooling --tag "$image" "$project/.guardrails/podman"
  for assertion in "$@"; do "$assertion" "$project" "$image"; done
)

# rq-276c546b
assert_versions_match_recording() {
  local project="$1" image="$2"
  local claude_recorded codex_recorded reported
  claude_recorded="$(build_key "$project" CLAUDE_VERSION)"
  codex_recorded="$(build_key "$project" CODEX_VERSION)"
  test -n "$claude_recorded" || fail 'no CLAUDE_VERSION is recorded'
  test -n "$codex_recorded" || fail 'no CODEX_VERSION is recorded'

  reported="$(podman run --rm "$image" claude --version)"
  grep -Fq "$claude_recorded" <<<"$reported" || \
    fail "image reports Claude '$reported', but $claude_recorded is recorded"
  reported="$(podman run --rm "$image" codex --version)"
  grep -Fq "$codex_recorded" <<<"$reported" || \
    fail "image reports Codex '$reported', but $codex_recorded is recorded"
  test "$(podman image inspect --format '{{ index .Labels "io.guardrails.claude-version" }}' "$image")" = "$claude_recorded" || \
    fail 'Claude image label does not match the installed release'
  test "$(podman image inspect --format '{{ index .Labels "io.guardrails.codex-version" }}' "$image")" = "$codex_recorded" || \
    fail 'Codex image label does not match the installed release'
}

# The credential volumes mount over /root/.claude and /root/.codex, so an agent program
# installed beneath either path would be shadowed by the volume rather than pinned.
# rq-d09c17d0 rq-4e428654
assert_programs_and_config_outside_volumes() {
  local image="$2" resolved
  for agent in claude codex; do
    resolved="$(podman run --rm "$image" sh -c "readlink -f \"\$(command -v $agent)\"")"
    case "$resolved" in
      /root/.claude/*|/root/.codex/*)
        fail "$agent program resolves to $resolved, inside a credential volume mount point" ;;
      "") fail "$agent is not on PATH in the built image" ;;
    esac
  done
  podman run --rm "$image" sh -c 'test ! -e /root/.claude.json' || \
    fail 'image carries a build-time Claude configuration file'
  podman run --rm "$image" sh -c 'test ! -e /root/.claude' || \
    fail 'image carries a build-time Claude configuration directory'
  podman run --rm "$image" sh -c 'test ! -e /root/.codex' || \
    fail 'image carries build-time content under the Codex volume mount point'
}

# rq-fae13c6f
assert_autoupdaters_disabled() {
  local image="$2"
  test -n "$(podman run --rm "$image" printenv DISABLE_AUTOUPDATER)" || \
    fail 'the container environment does not set DISABLE_AUTOUPDATER'
}

# The tooling and agent installations occupy separate image definitions.
# rq-b25f8408
test_agents_are_isolated_from_tooling_image() (
  local temp project tooling agent project_container
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project rust "$project"
  tooling="$project/.guardrails/podman/Containerfile"
  agent="$project/.guardrails/podman/Agent.Containerfile"
  project_container="$project/Containerfile"
  ! grep -Eq 'claude\.ai/install\.sh|chatgpt\.com/codex/install\.sh' "$tooling" || fail 'tooling image installs agents'
  grep -Fq 'FROM localhost/guardrails-tooling:latest' "$agent" || fail 'agent image is not based on tooling'
  grep -Fq 'FROM localhost/guardrails-agent:latest' "$project_container" || fail 'project image is not based on agents'
)

# A build key change must rebuild the agent layers with no build argument, and an
# unchanged key must reuse them.
# rq-62939bfc rq-145d819f
test_build_key_drives_the_layer_cache() (
  local temp project image first second
  temp="$(mktemp -d)"; image="guardrails-cache-test-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project rust "$project"

  podman build --tag guardrails-tooling:latest "$project/.guardrails/podman" >/dev/null
  write_build_key "$project" 2.1.205 0.144.6 pinned
  podman build -f "$project/.guardrails/podman/Agent.Containerfile" --tag "$image" "$project/.guardrails/podman" >/dev/null
  first="$(podman run --rm "$image" claude --version)"

  second="$(podman build -f "$project/.guardrails/podman/Agent.Containerfile" --tag "$image" "$project/.guardrails/podman" 2>&1)"
  grep -Fq 'Using cache' <<<"$second" || fail 'an unchanged build key did not reuse cached layers'

  # 2.1.204 is an earlier published release; any release other than the first one
  # demonstrates that the key's contents alone drive the rebuild.
  write_build_key "$project" 2.1.204 0.144.6 pinned
  podman build -f "$project/.guardrails/podman/Agent.Containerfile" --tag "$image" "$project/.guardrails/podman" >/dev/null
  second="$(podman run --rm "$image" claude --version)"
  test "$first" != "$second" || fail 'changing the build key did not rebuild the agent layer'
  grep -Fq '2.1.204' <<<"$second" || fail "image reports '$second' after recording 2.1.204"
)

test_agent_pinning_in_rust_container() {
  with_built_image rust \
    assert_versions_match_recording \
    assert_programs_and_config_outside_volumes \
    assert_autoupdaters_disabled
}

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
test_agents_are_isolated_from_tooling_image
test_agent_pinning_in_rust_container
test_build_key_drives_the_layer_cache
printf 'PASS: generated development containers pin and provide agent tooling\n'
