#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The image-owned home directory the Containerfile establishes. Every program, toolchain, and agent
# configuration home lives beneath it so the image runs as an arbitrary unprivileged user.
RIPRAP_IMAGE_HOME=/opt/riprap/home

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
  podman build --tag "$image" "$project/.riprap/managed/container"
  version="$(podman run --rm "$image" copier --version)"
  major="$(printf '%s\n' "$version" | copier_major)"
  test "$major" = 9 || fail "expected Copier major 9 in $language image, got: $version"
)

build_key() {
  sed -n "s/^$2=//p" "$1/.riprap/state/container/agent-build.candidate.env" | tr -d '\r' | head -n 1
}

# The launcher normally writes the build key; container tests build the image directly,
# so they write the key themselves to control which releases the image installs.
write_build_key() {
  mkdir -p "$1/.riprap/state/container"
  printf 'CLAUDE_VERSION=%s\nCODEX_VERSION=%s\nOPENCODE_VERSION=%s\nREFRESH=%s\n' "$2" "$3" "$4" "$5" \
    > "$1/.riprap/state/container/agent-build.candidate.env"
}

build_agent_image() {
  local project="$1" image="$2" tooling_image="${3:-localhost/riprap-tooling:latest}" claude_version codex_version opencode_version
  claude_version="$(build_key "$project" CLAUDE_VERSION)"
  codex_version="$(build_key "$project" CODEX_VERSION)"
  opencode_version="$(build_key "$project" OPENCODE_VERSION)"
  podman build -f "$project/.riprap/managed/container/Agent.Containerfile" \
    --build-arg "CLAUDE_VERSION=$claude_version" \
    --build-arg "CODEX_VERSION=$codex_version" \
    --build-arg "OPENCODE_VERSION=$opencode_version" \
    --build-arg "RIPRAP_TOOLING_IMAGE=$tooling_image" \
    --tag "$image" "$project/.riprap/managed/container"
}

# Builds one image from a rendered project and runs every named assertion against it,
# so the agent downloads happen once rather than once per assertion.
with_built_image() (
  local language="$1"; shift
  local temp project image assertion tooling_image candidate_image project_id
  temp="$(mktemp -d)"
  image="riprap-agent-test-$language-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project "$language" "$project"
  # Exact releases rather than "latest", so the recorded value can be compared against
  # what the built image reports.
  write_build_key "$project" 2.1.205 0.144.6 1.15.11 pinned
  tooling_image="localhost/riprap-test-$language-$$-tooling:latest"
  candidate_image="localhost/riprap-test-$language-$$-agent:candidate"
  project_id=00000000-0000-4000-8000-000000000001
  podman build --tag "$tooling_image" "$project/.riprap/managed/container"
  build_agent_image "$project" "$candidate_image" "$tooling_image"
  podman build -f "$project/.riprap/managed/container/AgentLabels.Containerfile" \
    --build-arg CLAUDE_VERSION=2.1.205 --build-arg CODEX_VERSION=0.144.6 \
    --build-arg OPENCODE_VERSION=1.15.11 \
    --build-arg TOOLING_IMAGE_ID=test-tooling \
    --build-arg "RIPRAP_PROJECT_ID=$project_id" \
    --build-arg "RIPRAP_AGENT_CANDIDATE_IMAGE=$candidate_image" \
    --tag "$image" "$project/.riprap/managed/container"
  for assertion in "$@"; do "$assertion" "$project" "$image"; done
)

# rq-113ef8b2
assert_exported_image_keeps_image_owned_home() {
  local project="$1" image="$2" project_id output
  if ! command -v apptainer >/dev/null 2>&1; then
    printf 'SKIP: Apptainer is unavailable; exported-image execution test not run\n'
    return
  fi

  project_id="$(podman image inspect --format '{{ index .Labels "io.riprap.project-id" }}' "$image")"
  test -n "$project_id" || fail 'the test image has no project identity label'
  mkdir -p "$project/.riprap/state"
  printf '%s\n' "$project_id" > "$project/.riprap/state/project-id"
  (
    cd "$project"
    .riprap/managed/launch/export-sif.sh "$project_id" "$image"
  )

  output="$(
    printf '%s\n' \
      'set -e' \
      'copier --version' \
      'cargo --version' \
      'claude --version' \
      'codex --version' \
      'opencode --version' \
      'for program in copier cargo claude codex opencode; do readlink -f "$(command -v "$program")"; done' \
      'exit' |
      (cd "$project" && .riprap/managed/launch/apptainer-interface.sh "$project_id")
  )" || fail 'the exported image did not run successfully through the Apptainer launcher'

  grep -Eq '^copier 9\.' <<<"$output" || fail 'Copier is unavailable in the exported image'
  grep -Eq '^cargo 1\.' <<<"$output" || fail 'the Rust toolchain is unavailable in the exported image'
  grep -Fq '2.1.205' <<<"$output" || fail 'Claude is unavailable in the exported image'
  grep -Fq '0.144.6' <<<"$output" || fail 'Codex is unavailable in the exported image'
  grep -Fq '1.15.11' <<<"$output" || fail 'OpenCode is unavailable in the exported image'
  ! grep -Fq "$HOME/" <<<"$output" || fail 'a tested program resolved into the invoking user home'
}

# rq-276c546b
assert_versions_match_recording() {
  local project="$1" image="$2"
  local claude_recorded codex_recorded opencode_recorded reported
  claude_recorded="$(build_key "$project" CLAUDE_VERSION)"
  codex_recorded="$(build_key "$project" CODEX_VERSION)"
  opencode_recorded="$(build_key "$project" OPENCODE_VERSION)"
  test -n "$claude_recorded" || fail 'no CLAUDE_VERSION is recorded'
  test -n "$codex_recorded" || fail 'no CODEX_VERSION is recorded'
  test -n "$opencode_recorded" || fail 'no OPENCODE_VERSION is recorded'

  reported="$(podman run --rm "$image" claude --version)"
  grep -Fq "$claude_recorded" <<<"$reported" || \
    fail "image reports Claude '$reported', but $claude_recorded is recorded"
  reported="$(podman run --rm "$image" codex --version)"
  grep -Fq "$codex_recorded" <<<"$reported" || \
    fail "image reports Codex '$reported', but $codex_recorded is recorded"
  reported="$(podman run --rm "$image" opencode --version)"
  grep -Fq "$opencode_recorded" <<<"$reported" || \
    fail "image reports OpenCode '$reported', but $opencode_recorded is recorded"
  test "$(podman image inspect --format '{{ index .Labels "io.riprap.claude-version" }}' "$image")" = "$claude_recorded" || \
    fail 'Claude image label does not match the installed release'
  test "$(podman image inspect --format '{{ index .Labels "io.riprap.codex-version" }}' "$image")" = "$codex_recorded" || \
    fail 'Codex image label does not match the installed release'
  test "$(podman image inspect --format '{{ index .Labels "io.riprap.opencode-version" }}' "$image")" = "$opencode_recorded" || \
    fail 'OpenCode image label does not match the installed release'
}

# The credential mounts cover each agent's configuration home beneath the image-owned home
# directory, so an agent program installed beneath one of those paths would be shadowed by the
# mount rather than pinned.
# rq-d09c17d0 rq-4e428654 rq-aa0a9de2
assert_programs_and_config_outside_volumes() {
  local image="$2" resolved
  for agent in claude codex opencode; do
    resolved="$(podman run --rm "$image" sh -c "readlink -f \"\$(command -v $agent)\"")"
    case "$resolved" in
      "$RIPRAP_IMAGE_HOME"/.claude/*|"$RIPRAP_IMAGE_HOME"/.codex/*|"$RIPRAP_IMAGE_HOME"/.opencode/*)
        fail "$agent program resolves to $resolved, inside a credential mount point" ;;
      "") fail "$agent is not on PATH in the built image" ;;
    esac
  done
  podman run --rm "$image" sh -c "test ! -e $RIPRAP_IMAGE_HOME/.claude.json" || \
    fail 'image carries a build-time Claude configuration file'
  podman run --rm "$image" sh -c "test ! -e $RIPRAP_IMAGE_HOME/.claude" || \
    fail 'image carries a build-time Claude configuration directory'
  podman run --rm "$image" sh -c "test ! -e $RIPRAP_IMAGE_HOME/.codex" || \
    fail 'image carries build-time content under the Codex credential mount point'
  podman run --rm "$image" sh -c "test ! -e $RIPRAP_IMAGE_HOME/.opencode" || \
    fail 'image carries build-time content under the OpenCode credential mount point'
}

# rq-e7703bd3
# No program, toolchain, or agent configuration home may sit under /root, which is unreadable to
# any other user, and the image's home directory must be somewhere else entirely.
assert_nothing_installed_under_root() {
  local image="$2" home resolved
  home="$(podman run --rm "$image" printenv HOME)"
  test -n "$home" || fail 'the image sets no HOME'
  case "$home" in
    /root|/root/*) fail "the image home directory is $home, which no other user can read" ;;
  esac
  test "$home" = "$RIPRAP_IMAGE_HOME" || \
    fail "the image home directory is $home, not the expected $RIPRAP_IMAGE_HOME"
  for program in claude codex opencode copier; do
    resolved="$(podman run --rm "$image" sh -c "readlink -f \"\$(command -v $program)\"")"
    case "$resolved" in
      /root/*) fail "$program resolves to $resolved, which no other user can read" ;;
      "") fail "$program is not on PATH in the built image" ;;
    esac
  done
  podman run --rm "$image" sh -c 'test ! -d /root/.local/bin && test ! -d /root/.cargo' || \
    fail 'the image installs a toolchain under /root'
}

# rq-3640e734
# The same image must serve a runtime that maps the caller to root and one that runs the container
# as the invoking user, so every program has to work for an arbitrary uid. 65534 is the conventional
# unprivileged "nobody" uid and owns nothing in the image.
assert_image_runs_as_unprivileged_user() {
  local image="$2"
  podman run --rm --user 65534:65534 "$image" copier --version >/dev/null || \
    fail 'copier does not run as an unprivileged user'
  for agent in claude codex opencode; do
    podman run --rm --user 65534:65534 "$image" "$agent" --version >/dev/null || \
      fail "$agent does not run as an unprivileged user"
  done
  # Probe whichever language toolchain the image carries; the image installs exactly one.
  if podman run --rm "$image" sh -c 'command -v cargo' >/dev/null 2>&1; then
    podman run --rm --user 65534:65534 "$image" cargo --version >/dev/null || \
      fail 'the Rust toolchain does not run as an unprivileged user'
  fi
  if podman run --rm "$image" sh -c 'command -v python3' >/dev/null 2>&1; then
    podman run --rm --user 65534:65534 "$image" python3 --version >/dev/null || \
      fail 'the Python toolchain does not run as an unprivileged user'
  fi
}

# rq-56835ed3
# A runtime may present the image read-only, so nothing required at startup may be written to the
# image's own filesystem. The workspace and credential mounts stay writable.
assert_image_starts_read_only() {
  local image="$2" temp
  temp="$(mktemp -d)"
  podman run --rm --read-only \
    --tmpfs /tmp \
    -v "$temp:$RIPRAP_IMAGE_HOME/.claude" \
    "$image" claude --version >/dev/null || \
    { rm -rf "$temp"; fail 'the image does not start with a read-only image filesystem'; }
  podman run --rm --read-only --tmpfs /tmp "$image" sh -c 'echo ok' >/dev/null || \
    { rm -rf "$temp"; fail 'a shell does not start with a read-only image filesystem'; }
  rm -rf "$temp"
}

# rq-fae13c6f
assert_autoupdaters_disabled() {
  local image="$2"
  test -n "$(podman run --rm "$image" printenv DISABLE_AUTOUPDATER)" || \
    fail 'the container environment does not set DISABLE_AUTOUPDATER'
}

# Runs "opencode run" against a rendered project inside the agent image, reporting what OpenCode
# emitted in OPENCODE_OUTPUT and its exit status in OPENCODE_EXIT. Both travel in globals rather
# than on stdout because the exit status is the assertion: a caller that read the output through
# command substitution would run this in a subshell and lose the status with it. The project is
# copied inside the container and the mount is read-only, so an assertion that rewrites the managed
# check cannot disturb the copy a later assertion renders against. Git initialization gives the
# plugin an unambiguous worktree to resolve.
opencode_run_in_project() {
  local project="$1" image="$2" preparation="${3:-true}"
  OPENCODE_EXIT=0
  OPENCODE_OUTPUT="$(timeout 240 podman run --rm -v "$project:/project:ro" "$image" sh -c "
    mkdir -p /work && cp -a /project/. /work/ && cd /work
    git init -q . >/dev/null 2>&1 || true
    $preparation
    opencode run 'print the word hello' 2>&1")" || OPENCODE_EXIT=$?
}

# Observing OpenCode is what demonstrates this boundary: the plugin's source cannot distinguish a
# plugin OpenCode loads and honours from one it never invokes. Substituting a check that reports
# failure is what makes the rejecting path reachable from inside a container, because Riprap
# deliberately provides no way to make the canonical check report a chosen result.
#
# A refusal is recognised by what OpenCode does, not by what it prints: OpenCode renders a plugin
# refusal as a generic internal error naming neither Riprap nor the launcher, so matching text
# would assert something OpenCode does not promise. The refused and admitted outcomes are asserted
# by separate assertions that this suite runs against one image; their contrast is what separates
# a boundary that holds from a plugin that never ran.
# rq-b1c40a30 rq-91dd9910 rq-20e684a9 rq-f2003da4
assert_opencode_refuses_when_the_check_reports_failure() {
  local project="$1" image="$2"
  opencode_run_in_project "$project" "$image" \
    'printf "#!/bin/sh\nexit 2\n" > .riprap/managed/hooks/check-container.sh'
  test "$OPENCODE_EXIT" -ne 0 || \
    fail "OpenCode completed a request although the container check reported failure: $OPENCODE_OUTPUT"
}

# The canonical check succeeds inside the agent image, so the boundary must stay out of the way and
# OpenCode must reach its own handling of the prompt. Requiring a completed run is what keeps the
# refusing assertion meaningful: were OpenCode unable to run here at all, both outcomes would fail
# and the contrast that demonstrates the boundary would be gone.
# rq-2a2787e3
assert_opencode_admits_a_request_inside_the_container() {
  local project="$1" image="$2"
  opencode_run_in_project "$project" "$image"
  test "$OPENCODE_EXIT" -eq 0 || \
    fail "OpenCode did not handle a request inside the development container: $OPENCODE_OUTPUT"
}

# The tooling and agent installations occupy separate image definitions.
# rq-b25f8408
test_agents_are_isolated_from_tooling_image() (
  local temp project tooling agent project_container
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project rust "$project"
  tooling="$project/.riprap/managed/container/Containerfile"
  agent="$project/.riprap/managed/container/Agent.Containerfile"
  project_container="$project/Containerfile"
  ! grep -Eq 'claude\.ai/install\.sh|chatgpt\.com/codex/install\.sh|opencode\.ai/install' "$tooling" || fail 'tooling image installs agents'
  grep -Fq 'FROM ${RIPRAP_TOOLING_IMAGE}' "$agent" || fail 'agent image does not accept its scoped tooling image'
  grep -Fq 'FROM ${RIPRAP_AGENT_IMAGE}' "$project_container" || fail 'project image does not accept its scoped agent image'
)

# A build key change must rebuild the agent layers, and an unchanged key must reuse them.
# rq-62939bfc rq-145d819f
test_build_key_drives_the_layer_cache() (
  local temp project image first second tooling_image
  temp="$(mktemp -d)"; image="riprap-cache-test-$$"
  trap 'podman image rm --force "$image" >/dev/null 2>&1 || true; rm -rf "$temp"' EXIT
  project="$temp/project"
  render_project rust "$project"

  tooling_image="localhost/riprap-cache-test-$$-tooling:latest"
  podman build --tag "$tooling_image" "$project/.riprap/managed/container" >/dev/null
  write_build_key "$project" 2.1.205 0.144.6 1.15.11 pinned
  build_agent_image "$project" "$image" "$tooling_image" >/dev/null
  first="$(podman run --rm "$image" claude --version)"

  second="$(build_agent_image "$project" "$image" "$tooling_image" 2>&1)"
  grep -Fq 'Using cache' <<<"$second" || fail 'an unchanged build key did not reuse cached layers'

  # 2.1.204 is an earlier published release; any release other than the first one
  # demonstrates that the key's contents alone drive the rebuild.
  write_build_key "$project" 2.1.204 0.144.6 1.15.11 pinned
  build_agent_image "$project" "$image" "$tooling_image" >/dev/null
  second="$(podman run --rm "$image" claude --version)"
  test "$first" != "$second" || fail 'changing the build key did not rebuild the agent layer'
  grep -Fq '2.1.204' <<<"$second" || fail "image reports '$second' after recording 2.1.204"
)

test_agent_pinning_in_rust_container() {
  with_built_image rust \
    assert_versions_match_recording \
    assert_programs_and_config_outside_volumes \
    assert_nothing_installed_under_root \
    assert_image_runs_as_unprivileged_user \
    assert_image_starts_read_only \
    assert_exported_image_keeps_image_owned_home \
    assert_autoupdaters_disabled \
    assert_opencode_admits_a_request_inside_the_container \
    assert_opencode_refuses_when_the_check_reports_failure
}

# rq-e7703bd3 rq-3640e734 rq-56835ed3
# Unprivileged execution is a property of the image, so it is exercised for the Python variant too.
test_unprivileged_execution_in_python_container() {
  with_built_image python \
    assert_nothing_installed_under_root \
    assert_image_runs_as_unprivileged_user \
    assert_image_starts_read_only
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
  from="$(sed -n '1s/^FROM //p' "$project/.riprap/managed/container/Containerfile")"
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
  podman build --tag "$image" "$project/.riprap/managed/container"
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
  grep -Fqx "FROM $CUDA_BASE_IMAGE" "$project/.riprap/managed/container/Containerfile" || \
    fail 'the tooling image does not build on the chosen base image'
  grep -Fqx 'FROM ${RIPRAP_TOOLING_IMAGE}' "$project/.riprap/managed/container/Agent.Containerfile" || \
    fail 'the agent image does not accept the project-scoped tooling image'
  grep -Fqx 'FROM ${RIPRAP_AGENT_IMAGE}' "$project/Containerfile" || \
    fail 'the project-owned image does not accept the project-scoped agent image'
  ! grep -Eq 'claude|codex' "$project/.riprap/managed/container/Containerfile" || \
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
test_unprivileged_execution_in_python_container
test_build_key_drives_the_layer_cache
printf 'PASS: generated development containers pin and provide agent tooling\n'
