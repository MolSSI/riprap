#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

render_project() {
  if command -v copier >/dev/null 2>&1; then
    copier copy --trust --defaults --data project_name='Credential Test' \
      --data project_slug='credential-test' --data project_description='test' \
      --data language=rust --data include_rust_skeleton=false \
      --data author_name=Test --data author_email=test@example.com \
      --data open_source_license='Not Open Source' "$ROOT" "$1" >/dev/null
  else
    # A dependency-free fallback exercises static runtime files in minimal dev images.
    mkdir -p "$1"; cp -a "$ROOT/template/." "$1/"
    mv "$1/.gitignore.jinja" "$1/.gitignore"
    mv "$1/.guardrails/podman/image_name.jinja" "$1/.guardrails/podman/image_name"
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
exit 0
MOCK
  chmod +x "$MOCK_BIN/podman"
  export PATH="$MOCK_BIN:$PATH" PODMAN_LOG="$TEST_TMP/podman.log" MOCK_VOLUMES="$TEST_TMP/volumes"
  : > "$PODMAN_LOG"
}

# rq-9d9dea75
test_first_launch_isolated_volumes() (
  setup_project; cd "$PROJECT"; bash gr.sh </dev/null
  id=$(cat .guardrails/project-id)
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || fail 'invalid UUID'
  test -d "$MOCK_VOLUMES/guardrails-$id-claude"; test -d "$MOCK_VOLUMES/guardrails-$id-codex"
  ! grep -Eq " -v ${HOME}/\.(claude|codex|claude\.json)" "$PODMAN_LOG" || fail 'host agent configuration was mounted'
)

# rq-113c8ccd
test_later_launch_reuses_state() (
  setup_project; cd "$PROJECT"; .guardrails/credential-state.sh ensure >/dev/null
  id=$(cat .guardrails/project-id); touch "$MOCK_VOLUMES/guardrails-$id-claude/marker" "$MOCK_VOLUMES/guardrails-$id-codex/marker"
  bash gr.sh </dev/null
  test -f "$MOCK_VOLUMES/guardrails-$id-claude/marker"; test -f "$MOCK_VOLUMES/guardrails-$id-codex/marker"
)

# rq-6135fc70
test_bad_identity_blocks_podman() (
  setup_project; cd "$PROJECT"; printf 'bad\n' > .guardrails/project-id
  before=$(cksum .guardrails/project-id); ! bash gr.sh </dev/null 2>/dev/null || fail 'malformed ID accepted'
  test "$before" = "$(cksum .guardrails/project-id)"; test ! -s "$PODMAN_LOG"
  rm .guardrails/project-id; ln -s nowhere .guardrails/project-id
  ! bash gr.sh </dev/null 2>/dev/null || fail 'symlink ID accepted'; test -L .guardrails/project-id; test ! -s "$PODMAN_LOG"
)

# rq-f957f555
test_reset_is_project_and_agent_scoped() (
  setup_project; cd "$PROJECT"; .guardrails/credential-state.sh ensure >/dev/null; first=$(cat .guardrails/project-id)
  second=11111111-1111-4111-8111-111111111111
  mkdir "$MOCK_VOLUMES/guardrails-$second-claude" "$MOCK_VOLUMES/guardrails-$second-codex"
  bash gr.sh --reset-agent-state codex --yes >/dev/null
  test ! -d "$MOCK_VOLUMES/guardrails-$first-codex"; test -d "$MOCK_VOLUMES/guardrails-$first-claude"
  test -d "$MOCK_VOLUMES/guardrails-$second-claude"; test -d "$MOCK_VOLUMES/guardrails-$second-codex"
)

# rq-f8bf5e72
test_ignore_scope() (
  setup_project; cd "$PROJECT"; git init -q
  mkdir -p .codex .claude; touch .codex/auth.json .claude/.credentials.json .claude.json .env .env.local .env.prod.local
  for path in .codex/auth.json .claude/.credentials.json .claude.json .env .env.local .env.prod.local; do
    git check-ignore -q "$path" || fail "$path is not ignored"
  done
  ! git check-ignore -q .codex/hooks.json; ! git check-ignore -q .claude/settings.json; ! git check-ignore -q .agents/skills/gr-plan/SKILL.md
)

# rq-aeab49a7
test_staged_secrets_rejected_without_disclosure() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  token='sk-THISISANUNMISTAKABLYFAKETOKEN123456'; printf '%s\n' "$token" > accidental.txt; git add -f accidental.txt
  ! output=$(.guardrails/hooks/check-secrets.sh --staged 2>&1) || fail 'fake token accepted'
  grep -Fq 'accidental.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

# rq-0bb9767e
test_legitimate_integration_passes() (
  setup_project; cd "$PROJECT"; git init -q; git add .codex/hooks.json .claude/settings.json .agents/skills/gr-plan/SKILL.md
  .guardrails/hooks/check-secrets.sh --staged
)

# rq-50bb2037
test_hook_install_preserves_custom_path() (
  setup_project; cd "$PROJECT"; git init -q; git config core.hooksPath custom-hooks
  ! output=$(bash gr.sh --install-git-hooks 2>&1) || fail 'custom hooks replaced'
  test "$(git config core.hooksPath)" = custom-hooks; grep -Fq 'compose' <<<"$output"
)

# rq-ba5ee81b
test_repository_scan_needs_no_hook() (
  setup_project; cd "$PROJECT"; git init -q; git config user.email x@y; git config user.name x
  token='ghp_THISISANUNMISTAKABLYFAKETOKEN123456'; printf '%s\n' "$token" > tracked.txt
  git add -f tracked.txt; git commit -qm fake; test -z "$(git config --get core.hooksPath || true)"
  ! output=$(.guardrails/hooks/check-secrets.sh --repository 2>&1) || fail 'repository token accepted'
  grep -Fq 'tracked.txt (supported access token)' <<<"$output"; ! grep -Fq "$token" <<<"$output"
)

# rq-f63c0743 rq-cb2cdd8e
test_template_traceability_validation() (
  TEST_TMP="$(mktemp -d)"; trap 'rm -rf "$TEST_TMP"' EXIT
  mkdir -p "$TEST_TMP/template" "$TEST_TMP/rqm"
  printf 'rq-XXXXXXXX\n' > "$TEST_TMP/template/documentation.md"
  printf '{}\n' > "$TEST_TMP/rqm/registry.json"
  bash "$ROOT/tests/check_template_traceability.sh" "$TEST_TMP"
  printf 'rq-deadbeef\n' > "$TEST_TMP/template/offender.md"
  ! output=$(bash "$ROOT/tests/check_template_traceability.sh" "$TEST_TMP" 2>&1) || fail 'concrete template ID accepted'
  grep -Fq 'template/offender.md' <<<"$output"
)

# rq-70d8296b
test_generated_traceability_is_independent() (
  setup_project; cd "$PROJECT"; test ! -f rqm/registry.json
  printf '# Local feature\n\n## Scenario\n' > rqm/local.md
  .guardrails/skills/gr-plan/rqm.sh stamp rqm/local.md >/dev/null
  .guardrails/skills/gr-plan/rqm.sh index >/dev/null
  test -f rqm/registry.json
  ! cmp -s rqm/registry.json "$ROOT/rqm/registry.json" || fail 'Guardrails registry was copied'
)

test_first_launch_isolated_volumes; test_later_launch_reuses_state; test_bad_identity_blocks_podman
test_reset_is_project_and_agent_scoped; test_ignore_scope; test_staged_secrets_rejected_without_disclosure
test_legitimate_integration_passes; test_hook_install_preserves_custom_path; test_repository_scan_needs_no_hook
test_template_traceability_validation; test_generated_traceability_is_independent
printf 'PASS: credential isolation and traceability boundary\n'
