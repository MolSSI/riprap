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
    mv "$1/.riprap/podman/image_name.jinja" "$1/.riprap/podman/image_name"
    mv "$1/.claude/settings.json.jinja" "$1/.claude/settings.json"
  fi
}

setup_project() {
  TEST_TMP="$(mktemp -d)"; PROJECT="$TEST_TMP/project"; MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN" "$TEST_TMP/volumes"; render_project "$PROJECT"
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
  case "$*" in *' claude --version') echo '2.1.205 (Claude Code)' ;; *' codex --version') echo 'codex-cli 0.144.6' ;; esac
  exit
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  export PATH="$MOCK_BIN:$PATH" PODMAN_LOG="$TEST_TMP/podman.log" MOCK_VOLUMES="$TEST_TMP/volumes"
  : > "$PODMAN_LOG"
}

# rq-9d9dea75
test_first_launch_isolated_volumes() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  id=$(cat .riprap/project-id)
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || fail 'invalid UUID'
  test -d "$MOCK_VOLUMES/riprap-$id-claude"; test -d "$MOCK_VOLUMES/riprap-$id-codex"
  ! grep -Eq " -v ${HOME}/\.(claude|codex|claude\.json)" "$PODMAN_LOG" || fail 'host agent configuration was mounted'
)

# rq-113c8ccd
test_later_launch_reuses_state() (
  setup_project; cd "$PROJECT"; .riprap/credential-state.sh ensure >/dev/null
  id=$(cat .riprap/project-id); touch "$MOCK_VOLUMES/riprap-$id-claude/marker" "$MOCK_VOLUMES/riprap-$id-codex/marker"
  bash rr.sh </dev/null
  test -f "$MOCK_VOLUMES/riprap-$id-claude/marker"; test -f "$MOCK_VOLUMES/riprap-$id-codex/marker"
)

# rq-fb3e7cc2
test_claude_config_stored_in_volume() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  id=$(cat .riprap/project-id)
  # The Claude configuration directory must resolve to the same container path where the
  # persistent Claude volume is mounted, so the top-level configuration file is stored in
  # the volume rather than the disposable container.
  grep -Eq -- "-v riprap-$id-claude:/root/\.claude( |$)" "$PODMAN_LOG" || fail 'Claude volume not mounted at /root/.claude'
  grep -Eq -- "-e CLAUDE_CONFIG_DIR=/root/\.claude( |$)" "$PODMAN_LOG" || fail 'CLAUDE_CONFIG_DIR not pointed at the Claude volume'
)

# rq-6135fc70
test_bad_identity_blocks_podman() (
  setup_project; cd "$PROJECT"; printf 'bad\n' > .riprap/project-id
  before=$(cksum .riprap/project-id); ! bash rr.sh </dev/null 2>/dev/null || fail 'malformed ID accepted'
  test "$before" = "$(cksum .riprap/project-id)"; test ! -s "$PODMAN_LOG"
  rm .riprap/project-id; ln -s nowhere .riprap/project-id
  ! bash rr.sh </dev/null 2>/dev/null || fail 'symlink ID accepted'; test -L .riprap/project-id; test ! -s "$PODMAN_LOG"
)

# rq-f957f555
test_reset_is_project_and_agent_scoped() (
  setup_project; cd "$PROJECT"; .riprap/credential-state.sh ensure >/dev/null; first=$(cat .riprap/project-id)
  second=11111111-1111-4111-8111-111111111111
  mkdir "$MOCK_VOLUMES/riprap-$second-claude" "$MOCK_VOLUMES/riprap-$second-codex"
  bash rr.sh --reset-agent-state codex --yes >/dev/null
  test ! -d "$MOCK_VOLUMES/riprap-$first-codex"; test -d "$MOCK_VOLUMES/riprap-$first-claude"
  test -d "$MOCK_VOLUMES/riprap-$second-claude"; test -d "$MOCK_VOLUMES/riprap-$second-codex"
)

# rq-f8bf5e72
test_ignore_scope() (
  setup_project; cd "$PROJECT"; git init -q
  mkdir -p .codex .claude; touch .codex/auth.json .claude/.credentials.json .claude.json .env .env.local .env.prod.local
  for path in .codex/auth.json .claude/.credentials.json .claude.json .env .env.local .env.prod.local; do
    git check-ignore -q "$path" || fail "$path is not ignored"
  done
  ! git check-ignore -q .codex/hooks.json; ! git check-ignore -q .claude/settings.json; ! git check-ignore -q .agents/skills/rr-plan/SKILL.md
)

# rq-aeab49a7
test_staged_secrets_rejected_without_disclosure() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  # Assemble the fake token from a separate sigil and body so this test file never contains a
  # literal secret; otherwise the pre-commit scanner would reject the file when it is committed.
  fake=THISISANUNMISTAKABLYFAKETOKEN123456; token="sk-$fake"; printf '%s\n' "$token" > accidental.txt; git add -f accidental.txt
  ! output=$(.riprap/hooks/check-secrets.sh --staged 2>&1) || fail 'fake token accepted'
  grep -Fq 'accidental.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

# rq-0bb9767e
test_legitimate_integration_passes() (
  setup_project; cd "$PROJECT"; git init -q; git add .codex/hooks.json .claude/settings.json .agents/skills/rr-plan/SKILL.md
  .riprap/hooks/check-secrets.sh --staged
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
  ! output=$(.riprap/hooks/check-secrets.sh --repository 2>&1) || fail 'repository token accepted'
  grep -Fq 'tracked.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

build_key() { sed -n "s/^$1=//p" .riprap/podman/agent-build.env | head -n 1; }

# rq-7c6a2afa
test_unpinned_launch_records_week_and_latest() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = latest || fail 'Claude does not track the current release'
  test "$(build_key CODEX_VERSION)" = latest || fail 'Codex does not track the current release'
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || \
    fail "build key records '$(build_key REFRESH)' rather than the current ISO week"
)

# The build key's contents are the cache identity, so a second launch in the same week must
# leave it byte-identical; that is what keeps the agent layers cached.
# rq-145d819f
test_second_launch_in_same_week_is_unchanged() (
  setup_project; cd "$PROJECT"; bash rr.sh </dev/null
  before=$(cksum .riprap/podman/agent-build.env)
  bash rr.sh </dev/null
  test "$before" = "$(cksum .riprap/podman/agent-build.env)" || fail 'build key changed within one week'
)

# A new week must change the key. The stamp is compared against a key left over from an
# earlier week, which is exactly what the launcher sees on the first launch of a new week.
# rq-62939bfc
test_new_week_changes_the_build_key() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=latest\nCODEX_VERSION=latest\nREFRESH=1970-W01\n' \
    > .riprap/podman/agent-build.env
  bash rr.sh </dev/null
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || fail 'a new week did not update the build key'
)

# rq-c82c7b32
test_pin_installs_exact_release_and_suspends_refresh() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=2.1.205\nCODEX_VERSION=0.144.6\n' > .riprap/agent-pin.env
  bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = 2.1.205 || fail 'Claude pin not recorded'
  test "$(build_key CODEX_VERSION)" = 0.144.6 || fail 'Codex pin not recorded'
  test "$(build_key REFRESH)" = pinned || fail 'a fully pinned key still records a week'
  # A later week must not disturb a fully pinned key.
  before=$(cksum .riprap/podman/agent-build.env)
  bash rr.sh </dev/null
  test "$before" = "$(cksum .riprap/podman/agent-build.env)" || fail 'pinned key changed'
)

# An agent left out of the pin must keep tracking its current release, which requires the
# week to survive in the key.
# rq-c82c7b32
test_partial_pin_keeps_the_unpinned_agent_current() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=2.1.205\n' > .riprap/agent-pin.env
  bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = 2.1.205 || fail 'Claude pin not recorded'
  test "$(build_key CODEX_VERSION)" = latest || fail 'unpinned Codex was pinned'
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || \
    fail 'a partial pin suspended the refresh for the unpinned agent'
)

# rq-b06efb1e
test_removing_the_pin_restores_the_schedule() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=2.1.205\nCODEX_VERSION=0.144.6\n' > .riprap/agent-pin.env
  bash rr.sh </dev/null
  rm .riprap/agent-pin.env
  bash rr.sh </dev/null
  test "$(build_key CLAUDE_VERSION)" = latest || fail 'Claude did not return to the schedule'
  test "$(build_key REFRESH)" = "$(date -u +%G-W%V)" || fail 'the week was not restored'
)

# rq-6c8f6c05
test_malformed_pin_stops_the_launch() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=latest\n' > .riprap/agent-pin.env
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'a non-exact pin was accepted'
  grep -Fq 'CLAUDE_VERSION' <<<"$output" || fail 'the offending assignment is not identified'
  # Ensuring the credential volumes already logged podman calls, so look for a build.
  ! grep -q '^build ' "$PODMAN_LOG" || fail 'an image was built despite a malformed pin'
)

assert_invalid_pin() (
  setup_project; cd "$PROJECT"; printf '%b' "$1" > .riprap/agent-pin.env
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
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSION=latest\nCODEX_VERSION=latest\nREFRESH=1970-W01\nINSTALLED_CLAUDE_VERSION=1.0.0\nINSTALLED_CODEX_VERSION=1.0.0\n' > .riprap/podman/agent-build.env
  before=$(cksum .riprap/podman/agent-build.env)
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
  test "$before" = "$(cksum .riprap/podman/agent-build.env)" || fail 'failed refresh changed successful state'
  test ! -e .riprap/podman/agent-build.candidate.env || fail 'failed refresh left candidate state'
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
  test ! -e .riprap/podman/agent-build.candidate.env || fail 'tooling failure left candidate state'
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
    actual=$(.riprap/agent-build.sh week "${pair%%=*}")
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
  .riprap/agent-build.sh prepare
  refresh=$(sed -n 's/^REFRESH=//p' .riprap/podman/agent-build.candidate.env)
  test "$refresh" = 2042-W07 || fail 'the current refresh stamp did not use the portable date path'
)

# Validation precedence must not depend on which defect is checked first, or the two
# launchers would describe the same file differently.
# rq-c2cdf6d8
test_unknown_pin_name_outranks_a_bad_value() (
  setup_project; cd "$PROJECT"
  printf 'CLAUDE_VERSOIN=not-a-version\n' > .riprap/agent-pin.env
  ! output=$(bash rr.sh </dev/null 2>&1) || fail 'an unknown pin name was accepted'
  grep -Fq 'unknown assignment' <<<"$output" || fail 'the unknown name was not identified'
  ! grep -Fq 'exact release version' <<<"$output" || fail 'the value format outranked the unknown name'
)

# A launcher reads the release from the built image, never from its own environment.
# rq-fedf48c5
test_ambient_version_variable_is_ignored() (
  setup_project; cd "$PROJECT"
  CLAUDE_VERSION=9.9.9 CODEX_VERSION=8.8.8 bash rr.sh </dev/null
  test "$(build_key INSTALLED_CLAUDE_VERSION)" = 2.1.205 || \
    fail "recorded Claude release is '$(build_key INSTALLED_CLAUDE_VERSION)', not the one the image reports"
  test "$(build_key INSTALLED_CODEX_VERSION)" = 0.144.6 || \
    fail "recorded Codex release is '$(build_key INSTALLED_CODEX_VERSION)', not the one the image reports"
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
  test ! -e .riprap/podman/agent-build.env || fail 'an unparseable version was promoted'
)

# rq-ac53295e
test_build_key_is_not_committed() (
  setup_project; cd "$PROJECT"; git init -q; bash rr.sh </dev/null
  test -f .riprap/podman/agent-build.env || fail 'the launcher did not write a build key'
  git check-ignore -q .riprap/podman/agent-build.env || fail 'the build key is not git-ignored'
  printf 'candidate\n' > .riprap/podman/agent-build.candidate.env
  git check-ignore -q .riprap/podman/agent-build.candidate.env || fail 'candidate state is not git-ignored'
)

# The last interactive launch the mock recorded. The mock also logs the non-interactive
# "run --rm <image> <agent> --version" probes, which "-it" distinguishes from a session.
run_line() { grep '^run --rm -it ' "$PODMAN_LOG" | tail -n 1; }

# The template-owned arguments always end the run with the working directory, so anything
# a project enables appears between "-w /work" and the image name.
assert_run_tail() {
  local expected="$1" image
  image=$(cat .riprap/podman/image_name)
  [[ "$(run_line)" == *"-w /work ${expected}${image} bash" ]] || \
    fail "the run does not carry '${expected}' as its project options: $(run_line)"
}

write_run_options() { printf '%b' "$1" > .riprap/podman/run-options; }

# rq-83545aca
test_seeded_project_enables_no_run_options() (
  setup_project; cd "$PROJECT"
  test -f .riprap/podman/run-options || fail 'no run options file was seeded'
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
    .riprap/podman/run-options > run-options.new && mv run-options.new .riprap/podman/run-options
  grep -q '^--device=nvidia\.com/gpu=all$' .riprap/podman/run-options || \
    fail 'the seeded file carries no commented GPU device example'
  grep -q '^--security-opt=label=disable$' .riprap/podman/run-options || \
    fail 'the seeded file carries no commented SELinux labelling example'
  bash rr.sh </dev/null
  assert_run_tail '--device=nvidia.com/gpu=all --security-opt=label=disable '
)

# rq-a3420977
test_run_options_do_not_displace_template_configuration() (
  setup_project; cd "$PROJECT"
  write_run_options '--shm-size=8g\n'
  bash rr.sh </dev/null
  id=$(cat .riprap/project-id); line=$(run_line)
  grep -Eq -- "-v [^ ]+:/work( |$)" <<<"$line" || fail 'the workspace mount was displaced'
  grep -Fq -- "-v riprap-$id-claude:/root/.claude" <<<"$line" || fail 'the Claude volume was displaced'
  grep -Fq -- "-v riprap-$id-codex:/root/.codex" <<<"$line" || fail 'the Codex volume was displaced'
  grep -Fq -- '-e CLAUDE_CONFIG_DIR=/root/.claude' <<<"$line" || fail 'the agent configuration was displaced'
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
  rm .riprap/podman/run-options
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

# rq-d89e4c89
test_scripts_marked_lf() (
  setup_project; cd "$PROJECT"; git init -q
  for path in .riprap/hooks/pre-commit .riprap/hooks/check-secrets.sh rr.sh; do
    eol=$(attr_eol "$path"); test "$eol" = lf || fail "$path is not marked eol=lf (got '$eol')"
  done
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
  mkdir -p "$TEST_TMP/template/.riprap/podman" "$TEST_TMP/rqm"
  printf '{"rq-deadbeef": {"title": "A recorded Riprap requirement"}}\n' > "$TEST_TMP/rqm/registry.json"
  printf '# rq-deadbeef\n' > "$TEST_TMP/template/.riprap/podman/Containerfile.jinja"
  ! output=$(bash "$ROOT/tests/check_template_traceability.sh" "$TEST_TMP" 2>&1) || \
    fail 'a registry-recorded ID inside a hidden template directory was accepted'
  grep -Fq 'Containerfile.jinja' <<<"$output" || fail 'offending hidden path not identified'
)

# rq-70d8296b
test_generated_traceability_is_independent() (
  setup_project; cd "$PROJECT"; test ! -f rqm/registry.json
  printf '# Local feature\n\n## Scenario\n' > rqm/local.md
  .riprap/skills/rr-plan/rqm.sh stamp rqm/local.md >/dev/null
  .riprap/skills/rr-plan/rqm.sh index >/dev/null
  test -f rqm/registry.json
  ! cmp -s rqm/registry.json "$ROOT/rqm/registry.json" || fail 'Riprap registry was copied'
)

test_first_launch_isolated_volumes; test_later_launch_reuses_state; test_claude_config_stored_in_volume
test_scripts_marked_lf; test_batch_marked_crlf
test_bad_identity_blocks_podman
test_reset_is_project_and_agent_scoped; test_ignore_scope; test_staged_secrets_rejected_without_disclosure
test_legitimate_integration_passes; test_hook_install_preserves_custom_path; test_repository_scan_needs_no_hook
test_template_traceability_validation; test_template_traceability_scans_hidden_directories
test_generated_traceability_is_independent
test_unpinned_launch_records_week_and_latest; test_second_launch_in_same_week_is_unchanged
test_new_week_changes_the_build_key; test_pin_installs_exact_release_and_suspends_refresh
test_partial_pin_keeps_the_unpinned_agent_current; test_removing_the_pin_restores_the_schedule
test_malformed_pin_stops_the_launch; test_empty_pin_stops_launch; test_empty_pin_value_stops_launch
test_unknown_pin_name_stops_launch; test_duplicate_pin_name_stops_launch; test_malformed_pin_line_stops_launch
test_failed_refresh_falls_back_to_existing_image; test_failed_build_without_an_image_stops_the_launch
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
printf 'PASS: credential isolation and traceability boundary\n'
