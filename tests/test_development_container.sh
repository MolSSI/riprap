#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

copier_major() {
  sed -nE 's/^copier ([0-9]+)(\..*)?$/\1/p' | head -n 1
}

test_copier_version_parser_ignores_base_image_banner() {
  local output
  output='CUDA Version 12.6.3

copier 9.17.0'
  test "$(printf '%s\n' "$output" | copier_major)" = 9 ||
    fail 'Copier version parsing was confused by a base-image startup banner'
}

render_project() {
  local language="$1" destination="$2"
  local skeleton_key="include_${language}_skeleton"
  copier copy --trust --defaults --vcs-ref HEAD \
    --data project_name="Riprap ${language} Test" \
    --data project_slug="riprap-${language}-test" \
    --data project_description='Exercises the Riprap development container' \
    --data language="$language" \
    --data "$skeleton_key=false" \
    --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' \
    --data open_source_license='Not Open Source' \
    "$ROOT" "$destination"
}

assert_copier_in_container() (
  local language="$1"
  local temp project image version major
  temp="$(mktemp -d)"
  image="riprap-copier-test-$language"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"

  render_project "$language" "$project"
  podman build --tag "$image" "$project/.riprap/managed/podman"
  version="$(podman run --rm "$image" copier --version)"
  major="$(printf '%s\n' "$version" | copier_major)"
  test "$major" = 9 || fail "expected Copier major 9 in $language image, got: $version"
)

build_key() {
  sed -n "s/^$2=//p" "$1/.riprap/state/podman/agent-build.candidate.env" | tr -d '\r' | head -n 1
}

# The launcher normally writes the build key; container tests build the image directly,
# so they write the key themselves to control which releases the image installs.
write_build_key() {
  mkdir -p "$1/.riprap/state/podman"
  printf 'CLAUDE_VERSION=%s\nCODEX_VERSION=%s\nREFRESH=%s\n' "$2" "$3" "$4" \
    > "$1/.riprap/state/podman/agent-build.candidate.env"
}

build_agent_image() {
  local project="$1" image="$2" claude_version codex_version
  claude_version="$(build_key "$project" CLAUDE_VERSION)"
  codex_version="$(build_key "$project" CODEX_VERSION)"
  podman build -f "$project/.riprap/managed/podman/Agent.Containerfile" \
    --build-arg "CLAUDE_VERSION=$claude_version" \
    --build-arg "CODEX_VERSION=$codex_version" \
    --tag "$image" "$project/.riprap/managed/podman"
}

# Builds one image from a rendered project and runs every named assertion against it,
# so the agent downloads happen once rather than once per assertion.
with_built_image() (
  local language="$1"; shift
  local temp project image assertion
  temp="$(mktemp -d)"
  image="riprap-agent-test-$language-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project "$language" "$project"
  # Exact releases rather than "latest", so the recorded value can be compared against
  # what the built image reports.
  write_build_key "$project" 2.1.205 0.144.6 pinned
  podman build --tag riprap-tooling:latest "$project/.riprap/managed/podman"
  build_agent_image "$project" riprap-agent:candidate
  podman build -f "$project/.riprap/managed/podman/AgentLabels.Containerfile" \
    --build-arg CLAUDE_VERSION=2.1.205 --build-arg CODEX_VERSION=0.144.6 \
    --build-arg TOOLING_IMAGE_ID=test-tooling --tag "$image" "$project/.riprap/managed/podman"
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
  test "$(podman image inspect --format '{{ index .Labels "io.riprap.claude-version" }}' "$image")" = "$claude_recorded" || \
    fail 'Claude image label does not match the installed release'
  test "$(podman image inspect --format '{{ index .Labels "io.riprap.codex-version" }}' "$image")" = "$codex_recorded" || \
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
  tooling="$project/.riprap/managed/podman/Containerfile"
  agent="$project/.riprap/managed/podman/Agent.Containerfile"
  project_container="$project/Containerfile"
  ! grep -Eq 'claude\.ai/install\.sh|chatgpt\.com/codex/install\.sh' "$tooling" || fail 'tooling image installs agents'
  grep -Fq 'FROM localhost/riprap-tooling:latest' "$agent" || fail 'agent image is not based on tooling'
  grep -Fq 'FROM localhost/riprap-agent:latest' "$project_container" || fail 'project image is not based on agents'
)

# A build key change must rebuild the agent layers, and an unchanged key must reuse them.
# rq-62939bfc rq-145d819f
test_build_key_drives_the_layer_cache() (
  local temp project image first second
  temp="$(mktemp -d)"; image="riprap-cache-test-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project rust "$project"

  podman build --tag riprap-tooling:latest "$project/.riprap/managed/podman" >/dev/null
  write_build_key "$project" 2.1.205 0.144.6 pinned
  build_agent_image "$project" "$image" >/dev/null
  first="$(podman run --rm "$image" claude --version)"

  second="$(build_agent_image "$project" "$image" 2>&1)"
  grep -Fq 'Using cache' <<<"$second" || fail 'an unchanged build key did not reuse cached layers'

  # 2.1.204 is an earlier published release; any release other than the first one
  # demonstrates that the key's contents alone drive the rebuild.
  write_build_key "$project" 2.1.204 0.144.6 pinned
  build_agent_image "$project" "$image" >/dev/null
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

render_project_with_base_image() {
  local language="$1" destination="$2" base_image="$3"
  copier copy --trust --defaults --vcs-ref HEAD \
    --data project_name="Riprap ${language} Test" \
    --data project_slug="riprap-${language}-test" \
    --data project_description='Exercises the Riprap development container' \
    --data language="$language" \
    --data "include_${language}_skeleton=false" \
    --data base_image="$base_image" \
    --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' \
    --data open_source_license='Not Open Source' \
    "$ROOT" "$destination"
}

# An Ubuntu-derived CUDA development image. It supplies nvcc without requiring a GPU to be
# present on the builder, which is what lets this run on an ordinary runner.
CUDA_BASE_IMAGE="${RIPRAP_TEST_CUDA_IMAGE:-nvidia/cuda:12.6.3-devel-ubuntu24.04}"

# rq-c75bb5d9
test_default_base_image_is_ubuntu_lts() (
  local temp project from year
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT; project="$temp/project"
  render_project rust "$project"
  from="$(sed -n '1s/^FROM //p' "$project/.riprap/managed/podman/Containerfile")"
  # Ubuntu LTS releases carry an even year and an .04 month.
  grep -Eq '^ubuntu:[0-9][0-9]\.04$' <<<"$from" || fail "the default base image is '$from', not an Ubuntu LTS release"
  year="${from#ubuntu:}"; year="${year%%.*}"
  test $(( year % 2 )) -eq 0 || fail "the default base image '$from' is not an LTS release"
)

# rq-d6488ee9
test_gpu_base_image_carries_the_tooling_layer() (
  local temp project image version
  temp="$(mktemp -d)"; image="riprap-cuda-test-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project_with_base_image rust "$project" "$CUDA_BASE_IMAGE"
  podman build --tag "$image" "$project/.riprap/managed/podman"
  version="$(podman run --rm "$image" copier --version)"
  test "$(printf '%s\n' "$version" | copier_major)" = 9 || \
    fail "expected Copier major 9 in the CUDA image, got: $version"
  podman run --rm "$image" cargo --version >/dev/null || \
    fail 'the Rust toolchain is missing from the CUDA tooling image'
  podman run --rm "$image" nvcc --version >/dev/null || \
    fail 'the CUDA compiler supplied by the base image is missing from the tooling image'
)

# rq-f2f0525e
test_layering_is_unaffected_by_the_base_image() (
  local temp project
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT; project="$temp/project"
  render_project_with_base_image rust "$project" "$CUDA_BASE_IMAGE"
  grep -Fqx "FROM $CUDA_BASE_IMAGE" "$project/.riprap/managed/podman/Containerfile" || \
    fail 'the tooling image does not build on the chosen base image'
  grep -Fqx 'FROM localhost/riprap-tooling:latest' "$project/.riprap/managed/podman/Agent.Containerfile" || \
    fail 'the agent image is not based on the tooling image'
  grep -Fqx 'FROM localhost/riprap-agent:latest' "$project/Containerfile" || \
    fail 'the project-owned image is not based on the agent image'
  ! grep -Eq 'claude|codex' "$project/.riprap/managed/podman/Containerfile" || \
    fail 'the tooling image installs an agent'
)

# The seeded file is where a project records GPU access, so an update that discarded a
# user's edit would silently disable their GPU.
# rq-2f86b6aa
test_update_preserves_enabled_run_options() (
  local temp source project options
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  source="$temp/source"; project="$temp/project"
  cp -a "$ROOT/." "$source/"; rm -rf "$source/.git"
  git -C "$source" init --quiet
  git -C "$source" config user.name 'Riprap Tests'; git -C "$source" config user.email 'riprap@example.com'
  git -C "$source" add .; git -C "$source" commit --quiet -m 'template v1'; git -C "$source" tag v1.0.0

  copier copy --trust --defaults --vcs-ref v1.0.0 \
    --data project_name='Update Test' --data project_slug='update-test' \
    --data project_description='test' --data language=rust --data include_rust_skeleton=false \
    --data author_name=Test --data author_email=test@example.com \
    --data open_source_license='Not Open Source' "$source" "$project" >/dev/null
  options="$project/.riprap/user/podman/run-options"
  printf -- '--device=nvidia.com/gpu=all\n' >> "$options"
  git -C "$project" init --quiet
  git -C "$project" config user.name 'Riprap Tests'; git -C "$project" config user.email 'riprap@example.com'
  git -C "$project" add .; git -C "$project" commit --quiet -m 'project with GPU access enabled'

  printf '\n# a later template revision\n' >> "$source/template/.riprap/user/podman/run-options"
  git -C "$source" add template/.riprap/user/podman/run-options
  git -C "$source" commit --quiet -m 'template v2'; git -C "$source" tag v2.0.0

  copier update --trust --defaults --vcs-ref v2.0.0 "$project" >/dev/null
  grep -Fqx -- '--device=nvidia.com/gpu=all' "$options" || \
    fail 'the update discarded the project'"'"'s enabled run option'
)

test_copier_version_parser_ignores_base_image_banner
test_default_base_image_is_ubuntu_lts
test_layering_is_unaffected_by_the_base_image
test_update_preserves_enabled_run_options
test_gpu_base_image_carries_the_tooling_layer
test_copier_in_rust_container
test_copier_in_python_container
test_agents_are_isolated_from_tooling_image
test_agent_pinning_in_rust_container
test_build_key_drives_the_layer_cache
printf 'PASS: generated development containers pin and provide agent tooling\n'
