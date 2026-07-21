#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

render_project() {
  if command -v copier >/dev/null 2>&1; then
    copier copy --trust --defaults --vcs-ref HEAD --data project_name='Credential Test' \
      --data project_slug='credential-test' --data project_description='test' \
      --data language=rust --data include_rust_skeleton=false \
      --data author_name=Test --data author_email=test@example.com \
      --data open_source_license='Not Open Source' "$ROOT" "$1" >/dev/null
  else
    # A dependency-free fallback exercises static runtime files in minimal dev images.
    mkdir -p "$1"; cp -a "$ROOT/template/." "$1/"
    mv "$1/.gitignore.jinja" "$1/.gitignore"
    mv "$1/.riprap/managed/container/image_name.jinja" "$1/.riprap/managed/container/image_name"
    mv "$1/.claude/settings.json.jinja" "$1/.claude/settings.json"
  fi
}

setup_project() {
  TEST_TMP="$(mktemp -d)"; PROJECT="$TEST_TMP/project"; MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN" "$TEST_TMP/volumes"; render_project "$PROJECT"
  mkdir -p "$PROJECT/.riprap/state/container"
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1 $2" = 'volume rm' ]; then rm -rf "$MOCK_VOLUMES/$3"; exit; fi
if [ "$1 $2" = 'image inspect' ]; then
  case "$*" in *tooling-image-id*) echo tooling-id ;; *) echo tooling-id ;; esac
  exit
fi
if [ "$1 $2" = 'run --rm' ]; then
  case "$*" in *' claude --version') echo '2.1.205 (Claude Code)' ;; *' codex --version') echo 'codex-cli 0.144.6' ;; *' opencode --version') echo '1.15.11' ;; esac
  exit
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  export PATH="$MOCK_BIN:$PATH" PODMAN_LOG="$TEST_TMP/podman.log" MOCK_VOLUMES="$TEST_TMP/volumes"
  : > "$PODMAN_LOG"
}

# rq-9d9dea75 rq-37192a21
test_first_launch_isolated_volumes() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  id=$(cat .riprap/state/project-id)
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || fail 'invalid UUID'
  test -d "$MOCK_VOLUMES/riprap-$id-claude"; test -d "$MOCK_VOLUMES/riprap-$id-codex"
  test -d "$MOCK_VOLUMES/riprap-$id-opencode"
  ! grep -Eq " -v ${HOME}/\.(claude|codex|opencode|claude\.json)" "$PODMAN_LOG" || fail 'host agent configuration was mounted'
)

# rq-113c8ccd
test_later_launch_reuses_state() (
  setup_project; cd "$PROJECT"; .riprap/managed/launch/credential-state.sh ensure >/dev/null
  id=$(cat .riprap/state/project-id); touch "$MOCK_VOLUMES/riprap-$id-claude/marker" "$MOCK_VOLUMES/riprap-$id-codex/marker" "$MOCK_VOLUMES/riprap-$id-opencode/marker"
  bash rr.sh </dev/null
  test -f "$MOCK_VOLUMES/riprap-$id-claude/marker"; test -f "$MOCK_VOLUMES/riprap-$id-codex/marker"; test -f "$MOCK_VOLUMES/riprap-$id-opencode/marker"
)

# rq-aa0a9de2
test_opencode_state_volume_and_wrapper() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  id=$(cat .riprap/state/project-id)
  grep -Eq -- "-v riprap-$id-opencode:/opt/riprap/home/\.opencode( |$)" "$PODMAN_LOG" || fail 'OpenCode state volume not mounted'
  grep -Fq 'XDG_DATA_HOME=/opt/riprap/home/.opencode/data' .riprap/managed/container/opencode || fail 'OpenCode data is not redirected into its volume'
  grep -Fq 'XDG_STATE_HOME=/opt/riprap/home/.opencode/state' .riprap/managed/container/opencode || fail 'OpenCode state is not redirected into its volume'
  grep -Fq 'OPENCODE_CONFIG_DIR=/opt/riprap/home/.opencode/config' .riprap/managed/container/opencode || fail 'OpenCode config is not redirected into its volume'
  # A launch into a fresh volume must not fail on a redirected path OpenCode does not create.
  grep -Eq '^mkdir -p .*/opt/riprap/home/\.opencode/config' .riprap/managed/container/opencode || \
    fail 'the wrapper does not prepare the redirected OpenCode directories'
  grep -Fq 'exec /opt/opencode/bin/opencode' .riprap/managed/container/opencode || fail 'OpenCode executable is not image-owned'
)

# rq-fb3e7cc2
test_claude_config_stored_in_volume() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  id=$(cat .riprap/state/project-id)
  # The Claude configuration directory must resolve to the same container path where the
  # persistent Claude volume is mounted, so the top-level configuration file is stored in
  # the volume rather than the disposable container.
  grep -Eq -- "-v riprap-$id-claude:/opt/riprap/home/\.claude( |$)" "$PODMAN_LOG" || fail 'Claude volume not mounted at /opt/riprap/home/.claude'
  grep -Eq -- "-e CLAUDE_CONFIG_DIR=/opt/riprap/home/\.claude( |$)" "$PODMAN_LOG" || fail 'CLAUDE_CONFIG_DIR not pointed at the Claude volume'
)

# rq-6135fc70
test_bad_identity_blocks_podman() (
  setup_project; cd "$PROJECT"; mkdir -p .riprap/state; printf 'bad\n' > .riprap/state/project-id
  before=$(cksum .riprap/state/project-id); ! bash rr.sh </dev/null 2>/dev/null || fail 'malformed ID accepted'
  test "$before" = "$(cksum .riprap/state/project-id)"; test ! -s "$PODMAN_LOG"
  rm .riprap/state/project-id; ln -s nowhere .riprap/state/project-id
  ! bash rr.sh </dev/null 2>/dev/null || fail 'symlink ID accepted'; test -L .riprap/state/project-id; test ! -s "$PODMAN_LOG"
)

# rq-f957f555
test_reset_is_project_and_agent_scoped() (
  setup_project; cd "$PROJECT"; .riprap/managed/launch/credential-state.sh ensure >/dev/null; first=$(cat .riprap/state/project-id)
  second=11111111-1111-4111-8111-111111111111
  mkdir "$MOCK_VOLUMES/riprap-$second-claude" "$MOCK_VOLUMES/riprap-$second-codex" "$MOCK_VOLUMES/riprap-$second-opencode"
  bash rr.sh --reset-agent-state codex --yes >/dev/null
  test ! -d "$MOCK_VOLUMES/riprap-$first-codex"; test -d "$MOCK_VOLUMES/riprap-$first-claude"
  test -d "$MOCK_VOLUMES/riprap-$first-opencode"
  test -d "$MOCK_VOLUMES/riprap-$second-claude"; test -d "$MOCK_VOLUMES/riprap-$second-codex"; test -d "$MOCK_VOLUMES/riprap-$second-opencode"
)

# rq-f8bf5e72
test_ignore_scope() (
  setup_project; cd "$PROJECT"; git init -q
  mkdir -p .codex .claude .opencode/data/opencode; touch .codex/auth.json .claude/.credentials.json .claude.json .opencode/data/opencode/auth.json .env .env.local .env.prod.local
  for path in .codex/auth.json .claude/.credentials.json .claude.json .opencode/data/opencode/auth.json .env .env.local .env.prod.local; do
    git check-ignore -q "$path" || fail "$path is not ignored"
  done
  ! git check-ignore -q .codex/hooks.json; ! git check-ignore -q .claude/settings.json; ! git check-ignore -q opencode.json; ! git check-ignore -q .opencode/plugins/check-container.js; ! git check-ignore -q .agents/skills/rr-plan/SKILL.md
)

# rq-aeab49a7
test_staged_secrets_rejected_without_disclosure() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  # Assemble the fake token from a separate sigil and body so this test file never contains a
  # literal secret; otherwise the pre-commit scanner would reject the file when it is committed.
  fake=THISISANUNMISTAKABLYFAKETOKEN123456; token="sk-$fake"; printf '%s\n' "$token" > accidental.txt; git add -f accidental.txt
  ! output=$(.riprap/managed/hooks/check-secrets.sh --staged 2>&1) || fail 'fake token accepted'
  grep -Fq 'accidental.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

# rq-0bb9767e
test_legitimate_integration_passes() (
  setup_project; cd "$PROJECT"; git init -q; git add .codex/hooks.json .claude/settings.json opencode.json .opencode/plugins/check-container.js .opencode/skills/rr-plan/SKILL.md .agents/skills/rr-plan/SKILL.md
  .riprap/managed/hooks/check-secrets.sh --staged
)

# rq-50bb2037
test_hook_install_preserves_custom_path() (
  setup_project; cd "$PROJECT"; git init -q; git config core.hooksPath custom-hooks
  ! output=$(bash rr.sh --install-git-hooks 2>&1) || fail 'custom hooks replaced'
  test "$(git config core.hooksPath)" = custom-hooks; grep -Fq 'compose' <<<"$output"
)

# rq-ba5ee81b
test_repository_scan_needs_no_hook() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  # Assemble the fake token at runtime (see test_staged_secrets_rejected_without_disclosure) so the
  # committed test file holds no literal secret for the pre-commit scanner to reject.
  fake=THISISANUNMISTAKABLYFAKETOKEN123456; token="ghp_$fake"; printf '%s\n' "$token" > tracked.txt
  git add -f tracked.txt; git commit -qm fake; test -z "$(git config --get core.hooksPath || true)"
  ! output=$(.riprap/managed/hooks/check-secrets.sh --repository 2>&1) || fail 'repository token accepted'
  grep -Fq 'tracked.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

# rq-a7cf7d43
test_staged_type_change_is_scanned() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  printf 'ordinary\n' > changed.txt; git add changed.txt; git commit -qm base
  rm changed.txt
  fake=THISISANUNMISTAKABLYFAKETOKEN123456; token="sk-$fake"
  ln -s "$token" changed.txt; git add changed.txt
  ! output=$(.riprap/managed/hooks/check-secrets.sh --staged 2>&1) || fail 'secret in a staged type change was accepted'
  grep -Fq 'changed.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

# rq-0a4106f0
test_repository_scan_is_directory_independent() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  mkdir -p nested/work
  fake=THISISANUNMISTAKABLYFAKETOKEN123456; token="ghp_$fake"
  printf '%s\n' "$token" > nested/tracked.txt; git add nested/tracked.txt; git commit -qm fake
  ! root_output=$(.riprap/managed/hooks/check-secrets.sh --repository 2>&1) || fail 'root scan accepted a token'
  cd nested/work
  ! nested_output=$(../../.riprap/managed/hooks/check-secrets.sh --repository 2>&1) || fail 'nested scan accepted a token'
  test "$root_output" = "$nested_output" || fail 'repository scan output depends on the caller directory'
  grep -Fq 'nested/tracked.txt (supported access token)' <<<"$nested_output"
)

# rq-0ce3a836
test_scan_outside_repository_fails() (
  setup_project; cd "$TEST_TMP"
  ! output=$("$PROJECT/.riprap/managed/hooks/check-secrets.sh" --repository 2>&1) || fail 'scan outside Git succeeded'
  grep -Fq 'not inside a Git working tree' <<<"$output" || fail 'outside-repository failure was not actionable'
)

# rq-cdb90fb3
test_unreadable_git_object_fails_closed() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  printf 'ordinary\n' > tracked.txt; git add tracked.txt; git commit -qm base
  real_git=$(command -v git); fake_bin="$TEST_TMP/fake-git"; mkdir "$fake_bin"
  sed "s|@REAL_GIT@|$real_git|" >"$fake_bin/git" <<'MOCK'
#!/bin/sh
if [ "$1" = show ]; then exit 1; fi
exec @REAL_GIT@ "$@"
MOCK
  chmod +x "$fake_bin/git"
  ! output=$(PATH="$fake_bin:$PATH" .riprap/managed/hooks/check-secrets.sh --repository 2>&1) ||
    fail 'unreadable Git object was treated as clean'
  grep -Fq "could not read Git object for path 'tracked.txt'" <<<"$output" ||
    fail 'unreadable object failure did not identify its path'
  ! grep -Fq 'ordinary' <<<"$output" || fail 'unreadable-object diagnostic disclosed content'
)

build_key() { sed -n "s/^$1=//p" .riprap/state/container/agent-build.env | head -n 1; }

# rq-7c6a2afa
test_unpinned_launch_records_week_and_latest() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = latest || fail 'Claude does not track the current release'
  test "$(build_key CODEX_VERSION)" = latest || fail 'Codex does not track the current release'
  test "$(build_key OPENCODE_VERSION)" = latest || fail 'OpenCode does not track the current release'
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || \
    fail "build key records '$(build_key REFRESH)' rather than the current ISO week"
)

# The build key's contents are the cache identity, so a second launch in the same week must
# leave it byte-identical; that is what keeps the agent layers cached.
# rq-145d819f
test_second_launch_in_same_week_is_unchanged() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  before=$(cksum .riprap/state/container/agent-build.env)
  bash rr.sh </dev/null
  test "$before" = "$(cksum .riprap/state/container/agent-build.env)" || fail 'build key changed within one week'
)

# A new week must change the key. The stamp is compared against a key left over from an
# earlier week, which is exactly what the launcher sees on the first launch of a new week.
# rq-62939bfc
test_new_week_changes_the_build_key() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=latest\nCODEX_VERSION=latest\nOPENCODE_VERSION=latest\nREFRESH=1970-W01\n' \
    > .riprap/state/container/agent-build.env
  bash rr.sh </dev/null
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || fail 'a new week did not update the build key'
)

# rq-c82c7b32
test_pin_installs_exact_release_and_suspends_refresh() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=2.1.205\nCODEX_VERSION=0.144.6\nOPENCODE_VERSION=1.15.11\n' > .riprap/user/agent-pin.env
  bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = 2.1.205 || fail 'Claude pin not recorded'
  test "$(build_key CODEX_VERSION)" = 0.144.6 || fail 'Codex pin not recorded'
  test "$(build_key OPENCODE_VERSION)" = 1.15.11 || fail 'OpenCode pin not recorded'
  test "$(build_key REFRESH)" = pinned || fail 'a fully pinned key still records a week'
  # A later week must not disturb a fully pinned key.
  before=$(cksum .riprap/state/container/agent-build.env)
  bash rr.sh </dev/null
  test "$before" = "$(cksum .riprap/state/container/agent-build.env)" || fail 'pinned key changed'
)

# An agent left out of the pin must keep tracking its current release, which requires the
# week to survive in the key.
# rq-c82c7b32
test_partial_pin_keeps_the_unpinned_agent_current() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=2.1.205\n' > .riprap/user/agent-pin.env
  bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = 2.1.205 || fail 'Claude pin not recorded'
  test "$(build_key CODEX_VERSION)" = latest || fail 'unpinned Codex was pinned'
  test "$(build_key OPENCODE_VERSION)" = latest || fail 'unpinned OpenCode was pinned'
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || \
    fail 'a partial pin suspended the refresh for the unpinned agent'
)

# rq-b06efb1e
test_removing_the_pin_restores_the_schedule() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=2.1.205\nCODEX_VERSION=0.144.6\nOPENCODE_VERSION=1.15.11\n' > .riprap/user/agent-pin.env
  bash rr.sh </dev/null
  rm .riprap/user/agent-pin.env
  bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = latest || fail 'Claude did not return to the schedule'
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || fail 'the week was not restored'
)

# rq-6c8f6c05
test_malformed_pin_stops_the_launch() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=latest\n' > .riprap/user/agent-pin.env
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'a non-exact pin was accepted'
  grep -Fq 'CLAUDE_VERSION' <<<"$output" || fail 'the offending assignment is not identified'
  # Ensuring the credential volumes already logged podman calls, so look for a build.
  ! grep -q '^build ' "$PODMAN_LOG" || fail 'an image was built despite a malformed pin'
)

assert_invalid_pin() (
  setup_project; cd "$PROJECT"; printf '%b' "$1" > .riprap/user/agent-pin.env
  ! output=$(bash rr.sh </dev/null 2>&1) || fail "$2 was accepted"
  grep -Fiq "$3" <<<"$output" || fail "$2 did not identify $3"
  ! grep -q '^build ' "$PODMAN_LOG" || fail "an image was built for $2"
)

# rq-0aa08b69
test_empty_pin_stops_launch() { assert_invalid_pin '' 'an empty pin' 'empty'; }

# rq-0b49d1fa
test_empty_pin_value_stops_launch() { assert_invalid_pin 'CLAUDE_VERSION=\n' 'an empty pin value' 'empty value'; }

# rq-5f5a1830
test_unknown_pin_name_stops_launch() { assert_invalid_pin 'CLAUDE_VERSOIN=1.2.3\n' 'an unknown pin name' 'unknown'; }

# rq-bba1fa27
test_duplicate_pin_name_stops_launch() {
  assert_invalid_pin 'CLAUDE_VERSION=1.2.3\nCLAUDE_VERSION=1.2.4\n' 'a duplicate pin name' 'duplicate'
}

# rq-08b8e355
test_malformed_pin_line_stops_launch() { assert_invalid_pin 'not-an-assignment\n' 'a malformed pin line' 'malformed'; }

# A refresh needs the network, so a failed build must not cost the user a working
# environment when a base image is already present.
# rq-dc4bf1b1
test_failed_refresh_falls_back_to_existing_image() (
  setup_project; cd "$PROJECT"; .riprap/managed/launch/credential-state.sh ensure >/dev/null
  id=$(cat .riprap/state/project-id)
  printf 'CLAUDE_VERSION=latest\nCODEX_VERSION=latest\nOPENCODE_VERSION=latest\nREFRESH=1970-W01\nINSTALLED_CLAUDE_VERSION=1.0.0\nINSTALLED_CODEX_VERSION=1.0.0\nINSTALLED_OPENCODE_VERSION=1.0.0\n' > .riprap/state/container/agent-build.env
  before=$(cksum .riprap/state/container/agent-build.env)
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1 $2" = 'image inspect' ]; then echo tooling-id; exit; fi
if [ "$1" = build ]; then case "$*" in *Agent.Containerfile*) exit 1 ;; esac; fi
if [ "$1 $2" = 'image exists' ]; then exit 0; fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  output=$(bash rr.sh </dev/null 2>&1) || fail 'launch aborted despite an existing base image'
  grep -Fq 'refresh failed' <<<"$output" || fail 'the failed refresh was not reported'
  grep -q 'run --rm' "$PODMAN_LOG" || fail 'no development container was started'
  grep -Fq "image exists localhost/riprap-$id-agent:latest" "$PODMAN_LOG" ||
    fail 'fallback did not inspect the project-scoped agent image'
  test "$before" = "$(cksum .riprap/state/container/agent-build.env)" || fail 'failed refresh changed successful state'
  test ! -e .riprap/state/container/agent-build.candidate.env || fail 'failed refresh left candidate state'
)

# rq-4155ad59
test_projects_use_distinct_image_names() (
  setup_project
  first="$PROJECT"; second="$TEST_TMP/second"
  render_project "$second"
  mkdir -p "$second/.riprap/state/container"
  cd "$first"; bash rr.sh </dev/null; first_id=$(cat .riprap/state/project-id)
  cd "$second"; bash rr.sh </dev/null; second_id=$(cat .riprap/state/project-id)
  test "$first_id" != "$second_id" || fail 'distinct projects received the same UUID'
  for id in "$first_id" "$second_id"; do
    grep -Fq "localhost/riprap-$id-tooling:latest" "$PODMAN_LOG" || fail "missing scoped tooling image for $id"
    grep -Fq "localhost/riprap-$id-agent:candidate" "$PODMAN_LOG" || fail "missing scoped candidate image for $id"
    grep -Fq "localhost/riprap-$id-agent:latest" "$PODMAN_LOG" || fail "missing scoped agent image for $id"
    grep -Fq "localhost/riprap-$id-project:latest" "$PODMAN_LOG" || fail "missing scoped project image for $id"
  done
  ! grep -Eq '(^|[[:space:]])riprap-(tooling|agent):(latest|candidate)($|[[:space:]])' "$PODMAN_LOG" ||
    fail 'launcher used a globally shared Riprap image name'
)

# rq-4155ad59
test_legacy_project_container_uses_scoped_agent_image() (
  setup_project; cd "$PROJECT"
  printf 'FROM localhost/riprap-agent:latest\nRUN true\n' > Containerfile
  bash rr.sh </dev/null
  id=$(cat .riprap/state/project-id)
  grep -Fqx 'ARG RIPRAP_AGENT_IMAGE' .riprap/state/container/Project.Containerfile ||
    fail 'legacy project Containerfile was not adapted'
  grep -Fqx 'FROM ${RIPRAP_AGENT_IMAGE}' .riprap/state/container/Project.Containerfile ||
    fail 'adapted project Containerfile still names the shared agent image'
  grep -Fq -- "-f .riprap/state/container/Project.Containerfile --build-arg RIPRAP_AGENT_IMAGE=localhost/riprap-$id-agent:latest" "$PODMAN_LOG" ||
    fail 'project build did not use its adapted Containerfile and scoped agent image'
)

# rq-8c24aa6e
test_fallback_cannot_select_another_projects_image() (
  setup_project; cd "$PROJECT"; .riprap/managed/launch/credential-state.sh ensure >/dev/null
  id=$(cat .riprap/state/project-id)
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1 $2" = 'image inspect' ]; then echo tooling-id; exit; fi
if [ "$1" = build ]; then case "$*" in *Agent.Containerfile*) exit 1 ;; esac; fi
if [ "$1 $2" = 'image exists' ]; then case "$3" in *"$PROJECT_ID"*) exit 1 ;; *) exit 0 ;; esac; fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  export PROJECT_ID="$id"
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'fallback selected another project image'
  grep -Fq 'no compatible agent image exists' <<<"$output" || fail 'cross-project fallback failure was not explained'
  grep -Fq "image exists localhost/riprap-$id-agent:latest" "$PODMAN_LOG" ||
    fail 'launcher did not limit fallback to its project image'
  ! grep -q 'run --rm -it' "$PODMAN_LOG" || fail 'container started from another project image'
)

# rq-152d1311
test_failed_build_without_an_image_stops_the_launch() (
  setup_project; cd "$PROJECT"
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1 $2" = 'image inspect' ]; then echo tooling-id; exit; fi
if [ "$1" = build ]; then case "$*" in *Agent.Containerfile*) exit 1 ;; esac; fi
if [ "$1 $2" = 'image exists' ]; then exit 1; fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'launch continued with no base image'
  grep -Fq 'no compatible agent image exists' <<<"$output" || fail 'the failure was not explained'
  ! grep -q 'run --rm' "$PODMAN_LOG" || fail 'a development container was started anyway'
)

# rq-4097cd5c
test_tooling_build_failure_never_falls_back() (
  setup_project; cd "$PROJECT"
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1" = build ]; then exit 1; fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'tooling build failure used fallback'
  grep -Fq 'tooling image build failed' <<<"$output" || fail 'tooling failure was not identified'
  ! grep -Fq 'agent refresh failed' <<<"$output" || fail 'tooling failure was mislabeled as refresh failure'
  test ! -e .riprap/state/container/agent-build.candidate.env || fail 'tooling failure left candidate state'
)

# The shell stamp is checked against ISO-8601 directly. Agreement between this
# implementation and the Windows one is established on a Windows runner, which is the only
# host that can execute both.
# rq-26d8643a
test_iso_week_matches_iso8601() (
  setup_project; cd "$PROJECT"
  for pair in 2019-12-30=2020-W01 2020-12-31=2020-W53 2021-01-01=2020-W53 \
              2021-01-04=2021-W01 2022-01-01=2021-W52 2024-12-30=2025-W01 \
              2026-12-31=2026-W53 2017-01-01=2016-W52 2023-06-15=2023-W24; do
    actual=$(.riprap/managed/launch/agent-build.sh week "${pair%%=*}")
    test "$actual" = "${pair#*=}" || fail "week ${pair%%=*} is '$actual', not '${pair#*=}'"
  done
)

# rq-cfefd5aa
test_current_iso_week_uses_portable_date_options() (
  setup_project; cd "$PROJECT"
  cat > "$MOCK_BIN/date" <<'MOCK'
#!/bin/sh
for argument in "$@"; do
  test "$argument" != -d || exit 64
done
printf '2042-W07\n'
MOCK
  chmod +x "$MOCK_BIN/date"
  .riprap/managed/launch/agent-build.sh prepare
  refresh=$(sed -n 's/^REFRESH=//p' .riprap/state/container/agent-build.candidate.env)
  test "$refresh" = 2042-W07 || fail 'the current refresh stamp did not use the portable date path'
)

# Validation precedence must not depend on which defect is checked first, or the two
# launchers would describe the same file differently.
# rq-c2cdf6d8
test_unknown_pin_name_outranks_a_bad_value() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSOIN=not-a-version\n' > .riprap/user/agent-pin.env
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'an unknown pin name was accepted'
  grep -Fq 'unknown assignment' <<<"$output" || fail 'the unknown name was not identified'
  ! grep -Fq 'exact release version' <<<"$output" || fail 'the value format outranked the unknown name'
)

# A launcher reads the release from the built image, never from its own environment.
# rq-fedf48c5
test_ambient_version_variable_is_ignored() (
  setup_project; cd "$PROJECT"
  CLAUDE_VERSION=9.9.9 CODEX_VERSION=8.8.8 OPENCODE_VERSION=7.7.7 bash rr.sh </dev/null
  test "$(build_key INSTALLED_CLAUDE_VERSION)" = 2.1.205 || \
    fail "recorded Claude release is '$(build_key INSTALLED_CLAUDE_VERSION)', not the one the image reports"
  test "$(build_key INSTALLED_CODEX_VERSION)" = 0.144.6 || \
    fail "recorded Codex release is '$(build_key INSTALLED_CODEX_VERSION)', not the one the image reports"
  test "$(build_key INSTALLED_OPENCODE_VERSION)" = 1.15.11 || \
    fail "recorded OpenCode release is '$(build_key INSTALLED_OPENCODE_VERSION)', not the one the image reports"
  ! grep -q '9\.9\.9' "$PODMAN_LOG" || fail 'an ambient CLAUDE_VERSION reached the image labels'
)

# rq-276c546b
# A version the launcher cannot parse is a refresh failure. The launcher is driven to that
# state and its effects observed, rather than its source being searched for a check.
# rq-41eeda01
test_unparseable_agent_version_fails_the_refresh() (
  setup_project; cd "$PROJECT"
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1 $2" = 'image inspect' ]; then echo tooling-id; exit; fi
if [ "$1 $2" = 'image exists' ]; then exit 1; fi
if [ "$1 $2" = 'run --rm' ]; then
  case "$*" in
    *' claude --version') echo 'unreleased-build' ;;
    *' codex --version') echo 'codex-cli 0.144.6' ;;
  esac
  exit
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  ! bash rr.sh </dev/null >/dev/null 2>&1 || fail 'an unparseable agent version was accepted'
  ! grep -q 'AgentLabels' "$PODMAN_LOG" || fail 'the agent image was labeled with an unparseable version'
  test ! -e .riprap/state/container/agent-build.env || fail 'an unparseable version was promoted'
)

# rq-ac53295e
test_build_key_is_not_committed() (
  setup_project; cd "$PROJECT"; git init -q; bash rr.sh </dev/null
  test -f .riprap/state/container/agent-build.env || fail 'the launcher did not write a build key'
  git check-ignore -q .riprap/state/container/agent-build.env || fail 'the build key is not git-ignored'
  printf 'candidate\n' > .riprap/state/container/agent-build.candidate.env
  git check-ignore -q .riprap/state/container/agent-build.candidate.env || fail 'candidate state is not git-ignored'
  # The project Containerfile is rewritten from the project's own on every launch, so it
  # describes this machine's image rather than the project.
  test -f .riprap/state/container/Project.Containerfile || \
    fail 'the launcher did not write a project Containerfile'
  git check-ignore -q .riprap/state/container/Project.Containerfile || \
    fail 'the generated project Containerfile is not git-ignored'
)

# The last interactive launch the mock recorded. The mock also logs the non-interactive
# "run --rm <image> <agent> --version" probes, which "-it" distinguishes from a session.
run_line() { grep '^run --rm -it ' "$PODMAN_LOG" | tail -n 1; }

# The template-owned arguments always end the run with the working directory, so anything
# a project enables appears between "-w /work" and the image name.
assert_run_tail() {
  local expected="$1" image id
  id=$(cat .riprap/state/project-id)
  image="localhost/riprap-$id-project:latest"
  [[ "$(run_line)" == *"-w /work ${expected}${image} bash" ]] || \
    fail "the run does not carry '${expected}' as its project options: $(run_line)"
}

write_run_options() { printf '%b' "$1" > .riprap/user/podman/run-options; }

# rq-83545aca
test_seeded_project_enables_no_run_options() (
  setup_project; cd "$PROJECT"
  test -f .riprap/user/podman/run-options || fail 'no run options file was seeded'
  bash rr.sh </dev/null
  assert_run_tail ''
)

# rq-7471ee4f
test_enabled_run_option_reaches_the_runtime() (
  setup_project; cd "$PROJECT"
  write_run_options '--shm-size=8g\n'
  bash rr.sh </dev/null
  assert_run_tail '--shm-size=8g '
)

# The delivered example is the whole point of seeding a commented file, so it is enabled
# the way a user would enable it rather than retyped here.
# rq-f881a732
test_delivered_gpu_example_can_be_enabled() (
  setup_project; cd "$PROJECT"
  sed 's/^# \(--device=nvidia\.com\/gpu=all\)$/\1/; s/^# \(--security-opt=label=disable\)$/\1/' \
    .riprap/user/podman/run-options > run-options.new && mv run-options.new .riprap/user/podman/run-options
  grep -q '^--device=nvidia\.com/gpu=all$' .riprap/user/podman/run-options || \
    fail 'the seeded file carries no commented GPU device example'
  grep -q '^--security-opt=label=disable$' .riprap/user/podman/run-options || \
    fail 'the seeded file carries no commented SELinux labelling example'
  bash rr.sh </dev/null
  assert_run_tail '--device=nvidia.com/gpu=all --security-opt=label=disable '
)

# rq-a3420977
test_run_options_do_not_displace_template_configuration() (
  setup_project; cd "$PROJECT"
  write_run_options '--shm-size=8g\n'
  bash rr.sh </dev/null
  id=$(cat .riprap/state/project-id); line=$(run_line)
  grep -Eq -- "-v [^ ]+:/work( |$)" <<<"$line" || fail 'the workspace mount was displaced'
  grep -Fq -- "-v riprap-$id-claude:/opt/riprap/home/.claude" <<<"$line" || fail 'the Claude volume was displaced'
  grep -Fq -- "-v riprap-$id-codex:/opt/riprap/home/.codex" <<<"$line" || fail 'the Codex volume was displaced'
  grep -Fq -- "-v riprap-$id-opencode:/opt/riprap/home/.opencode" <<<"$line" || fail 'the OpenCode volume was displaced'
  grep -Fq -- '-e CLAUDE_CONFIG_DIR=/opt/riprap/home/.claude' <<<"$line" || fail 'the agent configuration was displaced'
  assert_run_tail '--shm-size=8g '
)

# rq-173cab03
test_comments_and_blank_lines_enable_nothing() (
  setup_project; cd "$PROJECT"
  write_run_options '# a comment\n\n   # an indented comment\n\t\n'
  bash rr.sh </dev/null
  assert_run_tail ''
)

# rq-b6ce2749
test_absent_run_options_file_enables_nothing() (
  setup_project; cd "$PROJECT"
  rm .riprap/user/podman/run-options
  bash rr.sh </dev/null || fail 'a deleted run options file stopped the launch'
  assert_run_tail ''
)

# The message text is asserted verbatim because the Windows launcher is held to the same
# text; see the matching assertions in tests/test_windows_launcher.ps1.
assert_invalid_run_option() (
  setup_project; cd "$PROJECT"; write_run_options "$1"
  ! output=$(bash rr.sh </dev/null 2>&1) || fail "$2 was accepted"
  grep -Fq -- "$3" <<<"$output" || fail "$2 did not report: $3"
  grep -Fq -- "$4" <<<"$output" || fail "$2 did not identify the offending line"
  ! grep -q '^run --rm -it ' "$PODMAN_LOG" || fail "a container started despite $2"
)

# rq-32ffafe7 rq-0e32b682
test_run_option_with_whitespace_stops_the_launch() {
  assert_invalid_run_option '--device nvidia.com/gpu=all\n' 'an option written as two arguments' \
    'an option must be a single argument with no spaces' '--device nvidia.com/gpu=all'
}

# rq-eb18200a rq-0e32b682
test_run_option_that_is_not_an_option_stops_the_launch() {
  assert_invalid_run_option 'device=all\n' 'a line that is not an option' \
    "an option must begin with '-'" 'device=all'
}

# A line with both defects must be reported the same way by every launcher, so the
# whitespace check is fixed ahead of the leading-dash check.
# rq-0e32b682
test_whitespace_outranks_a_missing_leading_dash() {
  assert_invalid_run_option 'device all\n' 'a line with both defects' \
    'an option must be a single argument with no spaces' 'device all'
}

# A terminal carriage return is CRLF syntax, but an embedded one is whitespace and must
# not be silently removed from an option before validation.
# rq-32ffafe7 rq-0e32b682
test_run_option_with_embedded_carriage_return_stops_the_launch() {
  assert_invalid_run_option '--label=first\rsecond\n' 'an option containing an embedded carriage return' \
    'an option must be a single argument with no spaces' '--label=first'
}

attr_eol() { git check-attr eol -- "$1" | sed 's/.*: eol: //'; }

# A file is a script when its name carries a script extension, or when its first line is a "#!"
# line naming a shell or PowerShell interpreter. Discovering scripts from content rather than
# from a maintained list is what lets a script added to the template be covered as soon as it is
# committed, including the tool-mandated names that cannot take an extension. Each discovered
# path is printed with a tab and the endings its interpreter needs.
# rq-9332ad0f
discover_scripts() {
  local path first interpreter
  git add -A >/dev/null 2>&1 || true
  while IFS= read -r path; do
    case "$path" in
      *.sh|*.ps1) printf '%s\tlf\n' "$path"; continue ;;
      *.bat|*.cmd) printf '%s\tcrlf\n' "$path"; continue ;;
    esac
    [ -f "$path" ] || continue
    first=$(head -n 1 -- "$path" 2>/dev/null | tr -d '\r')
    case "$first" in '#!'*) ;; *) continue ;; esac
    set -- ${first#\#!}
    interpreter=$(basename -- "${1:-}")
    [ "$interpreter" != env ] || interpreter=$(basename -- "${2:-}")
    case "$interpreter" in
      sh|bash|dash|ksh|zsh|pwsh) printf '%s\tlf\n' "$path" ;;
    esac
  done < <(git ls-files)
}

# Reports every discovered script whose "eol" attribute is not the one its interpreter needs.
# Returning nonzero rather than exiting lets a caller assert the rejecting case as well.
# rq-9332ad0f
check_discovered_line_endings() {
  local path want eol status=0
  while IFS=$'\t' read -r path want; do
    [ -n "$path" ] || continue
    eol=$(attr_eol "$path")
    if [ "$eol" != "$want" ]; then
      printf '%s is not marked eol=%s (got %s)\n' "$path" "$want" "${eol:-unspecified}"
      status=1
    fi
  done
  return "$status"
}

# rq-d89e4c89
test_scripts_marked_lf() (
  setup_project; cd "$PROJECT"; git init -q
  discovered=$(discover_scripts)
  # The extensionless scripts prove discovery reads content; a name-based rule cannot find them.
  for required in .riprap/managed/hooks/pre-commit .riprap/managed/container/opencode; do
    grep -Fqx "$(printf '%s\tlf' "$required")" <<<"$discovered" || \
      fail "$required was not discovered as a script"
  done
  offenders=$(check_discovered_line_endings <<<"$discovered") || \
    fail "discovered scripts carry the wrong endings: $offenders"
)

# rq-1eda0111
test_uncovered_script_is_rejected() (
  setup_project; cd "$PROJECT"; git init -q
  mkdir -p devtools
  printf '#!/usr/bin/env bash\ntrue\n' > devtools/uncovered-helper
  discovered=$(discover_scripts)
  grep -Fqx "$(printf 'devtools/uncovered-helper\tlf')" <<<"$discovered" || \
    fail 'an extensionless shell script was not discovered'
  test "$(attr_eol devtools/uncovered-helper)" != lf || \
    fail 'the fixture is already covered by a rule, so it cannot exercise rejection'
  offenders=$(check_discovered_line_endings <<<"$discovered") && \
    fail 'validation accepted a script that no line-ending rule covers'
  grep -Fq devtools/uncovered-helper <<<"$offenders" || \
    fail "the rejection does not name the uncovered file: $offenders"
)

# rq-dbd3a295
test_batch_marked_crlf() (
  setup_project; cd "$PROJECT"; git init -q
  eol=$(attr_eol rr.bat); test "$eol" = crlf || fail "rr.bat is not marked eol=crlf (got '$eol')"
)

# Only identifiers the registry records are Riprap identifiers. Illustrative identifiers in
# template documentation and in the requirements tooling's fixtures are legitimate content.
# rq-f63c0743 rq-cb2cdd8e
test_template_traceability_validation() (
  TEST_TMP="$(mktemp -d)"; trap 'rm -rf "$TEST_TMP"' EXIT
  mkdir -p "$TEST_TMP/template/.riprap" "$TEST_TMP/rqm"
  printf '{"rq-deadbeef": {"title": "A recorded Riprap requirement"}}\n' > "$TEST_TMP/rqm/registry.json"
  # A placeholder and a well-formed identifier the registry does not record.
  printf 'rq-XXXXXXXX\n' > "$TEST_TMP/template/documentation.md"
  printf 'assert_stamped "<!-- rq-3a7f1c2e -->"\n' > "$TEST_TMP/template/.riprap/fixture.sh"
  bash "$ROOT/tests/check_template_traceability.sh" "$TEST_TMP" || \
    fail 'illustrative identifiers were rejected'

  printf 'rq-deadbeef\n' > "$TEST_TMP/template/offender.md"
  ! output=$(bash "$ROOT/tests/check_template_traceability.sh" "$TEST_TMP" 2>&1) || \
    fail 'a registry-recorded ID in the template tree was accepted'
  grep -Fq 'template/offender.md' <<<"$output" || fail 'offending path not identified'
)

# Most template content lives under hidden directories, so a check that skips them scans
# almost nothing.
# rq-59ada47d
test_template_traceability_scans_hidden_directories() (
  TEST_TMP="$(mktemp -d)"; trap 'rm -rf "$TEST_TMP"' EXIT
  mkdir -p "$TEST_TMP/template/.riprap/container" "$TEST_TMP/rqm"
  printf '{"rq-deadbeef": {"title": "A recorded Riprap requirement"}}\n' > "$TEST_TMP/rqm/registry.json"
  printf '# rq-deadbeef\n' > "$TEST_TMP/template/.riprap/container/Containerfile.jinja"
  ! output=$(bash "$ROOT/tests/check_template_traceability.sh" "$TEST_TMP" 2>&1) || \
    fail 'a registry-recorded ID inside a hidden template directory was accepted'
  grep -Fq 'Containerfile.jinja' <<<"$output" || fail 'offending hidden path not identified'
)

# ---------------------------------------------------------------------------
# Portable development image: export on a build host, run on an execution host.
# ---------------------------------------------------------------------------

# A mock Apptainer that logs its arguments, reports a chosen project-id label for "inspect", and
# writes a marker file for "build" so an export produces an image the run path can find. It logs to
# APPTAINER_LOG so a test can assert what the launcher issued without a real runtime.
install_mock_apptainer() {
  cat > "$MOCK_BIN/apptainer" <<'MOCK'
#!/bin/sh
echo "$*" >> "$APPTAINER_LOG"
case "$1" in
  inspect)
    for a in "$@"; do sif="$a"; done
    printf '{"data":{"attributes":{"labels":{"io.riprap.project-id":"%s"}}}}\n' "$(cat "${sif}.projectid" 2>/dev/null)"
    ;;
  build)
    dest="$2"; src="$3"; : > "$dest"
    printf '%s' "$MOCK_IMAGE_PROJECT_ID" > "${dest}.projectid"
    ;;
esac
exit 0
MOCK
  chmod +x "$MOCK_BIN/apptainer"
}

# A podman mock whose "save" leaves an OCI-archive marker and whose "image inspect" reports the
# project-id label, so the export path completes without a real runtime.
install_export_podman() {
  cat > "$MOCK_BIN/podman" <<'MOCK'
#!/bin/sh
echo "$*" >> "$PODMAN_LOG"
if [ "$1 $2" = 'volume inspect' ]; then [ -d "$MOCK_VOLUMES/$3" ]; exit; fi
if [ "$1 $2" = 'volume create' ]; then mkdir -p "$MOCK_VOLUMES/$3"; echo "$3"; exit; fi
if [ "$1 $2" = 'image inspect' ]; then echo tooling-id; exit; fi
if [ "$1 $2" = 'image exists' ]; then exit 0; fi
if [ "$1 $2" = 'run --rm' ]; then
  case "$*" in *' claude --version') echo '2.1.205 (Claude Code)' ;; *' codex --version') echo 'codex-cli 0.144.6' ;; *' opencode --version') echo '1.15.11' ;; esac
  exit
fi
if [ "$1" = save ]; then out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done; : > "$out"; exit 0; fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
}

apptainer_run_line() { grep '^shell ' "$APPTAINER_LOG" | tail -n 1; }

# Exporting builds the project image by the ordinary path, then writes a project-scoped single-file
# image under the apptainer state directory, and starts no container.
test_export_writes_a_project_scoped_image() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  export MOCK_IMAGE_PROJECT_ID=ignored
  install_export_podman; install_mock_apptainer
  bash rr.sh --export-sif </dev/null || fail 'export failed'
  id=$(cat .riprap/state/project-id)
  test -f ".riprap/state/apptainer/riprap-$id-project.sif" || fail 'no project-scoped image was written'
  grep -Fq "riprap-$id-project:latest" "$PODMAN_LOG" || fail 'the project image was not built before export'
  ! grep -q '^run --rm -it ' "$PODMAN_LOG" || fail 'export started an interactive container'
)

# A build host without Apptainer cannot export, and says so without leaving a partial image.
test_export_without_apptainer_stops() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  install_export_podman  # no apptainer mock installed
  ! output=$(bash rr.sh --export-sif </dev/null 2>&1) || fail 'export succeeded without Apptainer'
  grep -Fiq apptainer <<<"$output" || fail 'the failure did not name the missing runtime'
  id=$(cat .riprap/state/project-id)
  test ! -e ".riprap/state/apptainer/riprap-$id-project.sif" || fail 'a partial image was left behind'
)

# The exported image is scoped by the project UUID and its label records that UUID, so an execution
# host can tell which project an image belongs to.
test_export_labels_the_image_with_the_project() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  id=$(cat .riprap/state/project-id 2>/dev/null || true)
  install_export_podman; install_mock_apptainer
  bash rr.sh --export-sif </dev/null || fail 'export failed'
  id=$(cat .riprap/state/project-id)
  grep -Fq "RIPRAP_PROJECT_ID=$id" "$PODMAN_LOG" || fail 'the project-id was not passed as a build argument'
)

# Running an exported image binds the workspace and each credential directory, contains the host
# home and environment, and presents the image read-only with writable scratch. It builds nothing.
test_run_sif_isolates_and_binds() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  id=$(bash .riprap/managed/launch/credential-state.sh project-id)
  install_mock_apptainer
  export MOCK_IMAGE_PROJECT_ID="$id"
  sif=".riprap/state/apptainer/riprap-$id-project.sif"
  mkdir -p .riprap/state/apptainer; : > "$sif"; printf '%s' "$id" > "$sif.projectid"
  bash rr.sh --run-sif </dev/null || fail 'run-sif failed against a matching image'
  line=$(apptainer_run_line)
  grep -Fq -- '--containall' <<<"$line" || fail 'the run does not contain the host home directory'
  grep -Fq -- '--no-home' <<<"$line" || fail 'the run hides the image-owned home directory'
  grep -Fq -- '--cleanenv' <<<"$line" || fail 'the run does not supply a clean environment'
  grep -Fq -- '--writable-tmpfs' <<<"$line" || fail 'the run does not supply writable scratch space'
  grep -Eq -- '--bind [^ ]+/work:/work|--bind [^ ]+:/work' <<<"$line" || fail 'the workspace is not bound at /work'
  for agent in claude codex opencode; do
    grep -Fq -- "credentials/$agent:/opt/riprap/home/.$agent" <<<"$line" || fail "$agent credentials were not bound"
    test -d ".riprap/state/apptainer/credentials/$agent" || fail "$agent credential directory was not created"
  done
  grep -Fq -- '--env CLAUDE_CONFIG_DIR=/opt/riprap/home/.claude' <<<"$line" || fail 'the Claude config env was not set'
)

# Credential directories are created without group or other access on a shared host.
test_run_sif_credentials_are_private() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  id=$(cat .riprap/state/project-id 2>/dev/null || bash .riprap/managed/launch/credential-state.sh project-id)
  install_mock_apptainer; export MOCK_IMAGE_PROJECT_ID="$id"
  sif=".riprap/state/apptainer/riprap-$id-project.sif"
  mkdir -p .riprap/state/apptainer; : > "$sif"; printf '%s' "$id" > "$sif.projectid"
  bash rr.sh --run-sif </dev/null || fail 'run-sif failed'
  mode=$(stat -c '%a' .riprap/state/apptainer/credentials/claude)
  case "$mode" in *[1-7][0-7]|*[0-7][1-7]) fail "credential directory is group/other accessible: $mode" ;; esac
)

# An image built for another project is refused, naming both identities.
test_run_sif_refuses_a_foreign_image() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  id=$(cat .riprap/state/project-id 2>/dev/null || bash .riprap/managed/launch/credential-state.sh project-id)
  install_mock_apptainer; export MOCK_IMAGE_PROJECT_ID=foreign
  sif=".riprap/state/apptainer/riprap-$id-project.sif"
  mkdir -p .riprap/state/apptainer; : > "$sif"; printf 'foreign' > "$sif.projectid"
  ! output=$(bash rr.sh --run-sif </dev/null 2>&1) || fail 'a foreign image was accepted'
  grep -Fq foreign <<<"$output" || fail 'the refusal does not name the image project'
  grep -Fq "$id" <<<"$output" || fail 'the refusal does not name the workspace project'
  ! grep -q '^shell ' "$APPTAINER_LOG" || fail 'a container started despite the mismatch'
)

# A missing exported image is reported by the path the launcher expected.
test_run_sif_missing_image_names_the_path() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  install_mock_apptainer
  ! output=$(bash rr.sh --run-sif </dev/null 2>&1) || fail 'a missing image was accepted'
  grep -Fq '.riprap/state/apptainer/' <<<"$output" || fail 'the failure does not name the expected path'
)

# The execution host validates its own run-options file with the same rules and passes accepted
# options after the template-owned arguments.
test_run_sif_applies_execution_run_options() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  id=$(cat .riprap/state/project-id 2>/dev/null || bash .riprap/managed/launch/credential-state.sh project-id)
  install_mock_apptainer; export MOCK_IMAGE_PROJECT_ID="$id"
  sif=".riprap/state/apptainer/riprap-$id-project.sif"
  mkdir -p .riprap/state/apptainer; : > "$sif"; printf '%s' "$id" > "$sif.projectid"
  test -f .riprap/user/apptainer/run-options || fail 'no execution-host run options file was seeded'
  printf -- '--nv\n' > .riprap/user/apptainer/run-options
  bash rr.sh --run-sif </dev/null || fail 'run-sif failed with an enabled option'
  line=$(apptainer_run_line)
  [[ "$line" == *"--nv "*"riprap-$id-project.sif" ]] || fail "the option does not follow the template arguments: $line"
)

# An invalid execution-host option stops the launch before any container starts.
test_run_sif_rejects_an_invalid_option() (
  setup_project; cd "$PROJECT"
  export APPTAINER_LOG="$TEST_TMP/apptainer.log"; : > "$APPTAINER_LOG"
  id=$(cat .riprap/state/project-id 2>/dev/null || bash .riprap/managed/launch/credential-state.sh project-id)
  install_mock_apptainer; export MOCK_IMAGE_PROJECT_ID="$id"
  sif=".riprap/state/apptainer/riprap-$id-project.sif"
  mkdir -p .riprap/state/apptainer; : > "$sif"; printf '%s' "$id" > "$sif.projectid"
  printf -- '--bind /a /b\n' > .riprap/user/apptainer/run-options
  ! output=$(bash rr.sh --run-sif </dev/null 2>&1) || fail 'an invalid option was accepted'
  grep -Fq 'single argument with no spaces' <<<"$output" || fail 'the defect was not reported'
  ! grep -q '^shell ' "$APPTAINER_LOG" || fail 'a container started despite an invalid option'
)

# Reset removes the selected agent's execution-host credential directory and leaves the others. An
# execution host holds credential directories rather than volumes; with no volume present for the
# project, reset operates on the directories. The mock runtime reports no volumes, which is the same
# state reset sees whether the host has no build runtime at all or simply no volume for this project.
test_reset_removes_execution_host_directories() (
  setup_project; cd "$PROJECT"
  bash .riprap/managed/launch/credential-state.sh project-id >/dev/null
  for agent in claude codex opencode; do mkdir -p ".riprap/state/apptainer/credentials/$agent"; done
  bash rr.sh --reset-agent-state codex --yes >/dev/null || fail 'reset failed for execution-host state'
  test ! -d .riprap/state/apptainer/credentials/codex || fail 'the Codex directory was not removed'
  test -d .riprap/state/apptainer/credentials/claude || fail 'the Claude directory was removed'
  test -d .riprap/state/apptainer/credentials/opencode || fail 'the OpenCode directory was removed'
  # No volume exists for this project, so reset must not have issued a volume removal.
  ! grep -q "volume rm" "$PODMAN_LOG" || fail 'reset removed a volume when only directories exist'
)

# The exported image and the per-user credential directories are generated local state, ignored by
# version control.
test_execution_host_state_is_ignored() (
  setup_project; cd "$PROJECT"; git init -q
  mkdir -p .riprap/state/apptainer/credentials/claude
  : > .riprap/state/apptainer/riprap-x-project.sif
  git check-ignore -q .riprap/state/apptainer/riprap-x-project.sif || fail 'the exported image is not ignored'
  git check-ignore -q .riprap/state/apptainer/credentials/claude || fail 'the credential directory is not ignored'
  # A nested credential file, not only its directory, is ignored.
  mkdir -p .riprap/state/apptainer/credentials/codex
  : > .riprap/state/apptainer/credentials/codex/auth.json
  git check-ignore -q .riprap/state/apptainer/credentials/codex/auth.json || fail 'a nested credential file is not ignored'
  # An exported image is a build artifact wherever it lands, including outside the state directory.
  : > somewhere-else.sif
  git check-ignore -q somewhere-else.sif || fail 'a .sif outside the state directory is not ignored'
)

# rq-70d8296b
test_generated_traceability_is_independent() (
  setup_project; cd "$PROJECT"; test ! -f rqm/registry.json
  printf '# Local feature\n\n## Scenario\n' > rqm/local.md
  .riprap/managed/skills/rr-plan/rqm.sh stamp rqm/local.md >/dev/null
  .riprap/managed/skills/rr-plan/rqm.sh index >/dev/null
  test -f rqm/registry.json
  ! cmp -s rqm/registry.json "$ROOT/rqm/registry.json" || fail 'Riprap registry was copied'
)

test_first_launch_isolated_volumes; test_later_launch_reuses_state; test_claude_config_stored_in_volume
test_opencode_state_volume_and_wrapper
test_scripts_marked_lf; test_uncovered_script_is_rejected; test_batch_marked_crlf
test_bad_identity_blocks_podman
test_reset_is_project_and_agent_scoped; test_ignore_scope; test_staged_secrets_rejected_without_disclosure
test_legitimate_integration_passes; test_hook_install_preserves_custom_path; test_repository_scan_needs_no_hook
test_staged_type_change_is_scanned; test_repository_scan_is_directory_independent
test_scan_outside_repository_fails; test_unreadable_git_object_fails_closed
test_template_traceability_validation; test_template_traceability_scans_hidden_directories
test_generated_traceability_is_independent
test_unpinned_launch_records_week_and_latest; test_second_launch_in_same_week_is_unchanged
test_new_week_changes_the_build_key; test_pin_installs_exact_release_and_suspends_refresh
test_partial_pin_keeps_the_unpinned_agent_current; test_removing_the_pin_restores_the_schedule
test_malformed_pin_stops_the_launch; test_empty_pin_stops_launch; test_empty_pin_value_stops_launch
test_unknown_pin_name_stops_launch; test_duplicate_pin_name_stops_launch; test_malformed_pin_line_stops_launch
test_failed_refresh_falls_back_to_existing_image; test_failed_build_without_an_image_stops_the_launch
test_projects_use_distinct_image_names; test_legacy_project_container_uses_scoped_agent_image
test_fallback_cannot_select_another_projects_image
test_tooling_build_failure_never_falls_back; test_iso_week_matches_iso8601
test_current_iso_week_uses_portable_date_options
test_unparseable_agent_version_fails_the_refresh; test_unknown_pin_name_outranks_a_bad_value
test_ambient_version_variable_is_ignored
test_build_key_is_not_committed
test_seeded_project_enables_no_run_options; test_enabled_run_option_reaches_the_runtime
test_delivered_gpu_example_can_be_enabled; test_run_options_do_not_displace_template_configuration
test_comments_and_blank_lines_enable_nothing; test_absent_run_options_file_enables_nothing
test_run_option_with_whitespace_stops_the_launch
test_run_option_that_is_not_an_option_stops_the_launch
test_whitespace_outranks_a_missing_leading_dash
test_run_option_with_embedded_carriage_return_stops_the_launch
test_export_writes_a_project_scoped_image; test_export_without_apptainer_stops
test_export_labels_the_image_with_the_project
test_run_sif_isolates_and_binds; test_run_sif_credentials_are_private
test_run_sif_refuses_a_foreign_image; test_run_sif_missing_image_names_the_path
test_run_sif_applies_execution_run_options; test_run_sif_rejects_an_invalid_option
test_reset_removes_execution_host_directories; test_execution_host_state_is_ignored
printf 'PASS: credential isolation and traceability boundary\n'
