#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

render_project() {
  copier copy --trust --defaults --vcs-ref HEAD \
    --data project_name='Ownership Test' --data project_slug='ownership-test' \
    --data project_description='Exercises rendered ownership classes' \
    --data language=rust --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' --data open_source_license=MIT \
    "$ROOT" "$1" >/dev/null
}

is_approved_exception() {
  local project="$1" path="$2" pattern
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -n "$pattern" && "$pattern" != \#* ]] || continue
    case "$pattern" in
      */'**') [[ "$path" == "${pattern%/**}/"* ]] && return 0 ;;
      *) [[ "$path" == "$pattern" ]] && return 0 ;;
    esac
  done < "$project/.riprap/managed/ownership-exceptions"
  return 1
}

validate_project() {
  local project="$1" path first file
  while IFS= read -r -d '' file; do
    path="${file#"$project"/}"
    case "$path" in
      .riprap/managed/*|.riprap/user/*|.riprap/state/*) ;;
      *)
        if is_approved_exception "$project" "$path"; then
          continue
        fi
        first="$(sed -n '1p' "$file")"
        [[ "$first" != *Riprap-managed* ]] ||
          fail "managed path outside .riprap/managed is not approved: $path"
        ;;
    esac
  done < <(find "$project" -type f -print0)
}

# rq-b9f824f4
test_rendered_project_separates_ownership_classes() (
  local project="$1" skill
  validate_project "$project"
  for skill in rr-architecture rr-implement rr-plan rr-quiz; do
    test -f "$project/.riprap/managed/skills/$skill/SKILL.md" ||
      fail "missing managed $skill implementation"
    test -f "$project/.riprap/user/skills/$skill/local.md" ||
      fail "missing user-owned $skill customization"
  done
  test -f "$project/.riprap/user/podman/run-options" || fail 'missing user-owned run options'
)

# rq-7c9116c2
test_conventional_project_content_remains_user_owned() (
  local project="$1" path
  for path in README.md LICENSE Containerfile Cargo.toml src/lib.rs; do
    test -f "$project/$path" || fail "conventional user-owned path is missing: $path"
  done
)

# rq-37192a21
test_root_launchers_are_managed_adapters() (
  local project="$1"
  grep -Fq 'Riprap-managed adapter' "$project/rr.sh" || fail 'rr.sh is not visibly managed'
  grep -Fq '.riprap/managed/launch/rr.sh' "$project/rr.sh" || fail 'rr.sh does not delegate'
  grep -Fq 'Riprap-managed adapter' "$project/rr.bat" || fail 'rr.bat is not visibly managed'
  grep -Fq '.riprap\managed\launch\rr.bat' "$project/rr.bat" || fail 'rr.bat does not delegate'
  test -x "$project/rr.sh" || fail 'rr.sh is not executable'
)

# rq-c618df8b
test_unapproved_managed_exception_is_rejected() (
  local project="$1" output
  mkdir -p "$project/.github"
  printf '# Riprap-managed test file\n' > "$project/.github/unapproved.sh"
  ! output="$(validate_project "$project" 2>&1)" || fail 'unapproved managed exception was accepted'
  grep -Fq '.github/unapproved.sh' <<<"$output" || fail 'unapproved path was not identified'
)

# rq-e558bda9
test_layout_migration_preserves_existing_customizations() (
  local temp project migration
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$temp/project"
  migration="$ROOT/template/.riprap/managed/migrate-layout.py"
  mkdir -p "$project/.riprap/skills/rr-plan" "$project/.riprap/podman"
  printf 'user skill marker\n' > "$project/.riprap/skills/rr-plan/local.md"
  printf '%s\n' '--shm-size=8g' > "$project/.riprap/podman/run-options"
  printf '00000000-0000-4000-8000-000000000000\n' > "$project/.riprap/project-id"
  printf 'REFRESH=1970-W01\n' > "$project/.riprap/podman/agent-build.env"

  (cd "$project" && python3 "$migration")

  grep -Fq 'user skill marker' "$project/.riprap/user/skills/rr-plan/local.md" ||
    fail 'skill customization was not migrated'
  grep -Fq -- '--shm-size=8g' "$project/.riprap/user/podman/run-options" ||
    fail 'run options were not migrated'
  test -f "$project/.riprap/state/project-id" || fail 'shared project state was not migrated'
  test -f "$project/.riprap/state/podman/agent-build.env" || fail 'machine state was not migrated'
  test ! -e "$project/.riprap/skills/rr-plan/local.md" || fail 'old skill customization remains'
)

# rq-e558bda9
test_layout_migration_rejects_conflicting_customizations() (
  local temp project migration output
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$temp/project"
  migration="$ROOT/template/.riprap/managed/migrate-layout.py"
  mkdir -p "$project/.riprap/skills/rr-plan" "$project/.riprap/user/skills/rr-plan"
  printf 'old customization\n' > "$project/.riprap/skills/rr-plan/local.md"
  printf 'new customization\n' > "$project/.riprap/user/skills/rr-plan/local.md"

  ! output="$(cd "$project" && python3 "$migration" 2>&1)" ||
    fail 'conflicting customizations were silently accepted'
  grep -Fq 'reconcile them before updating' <<<"$output" || fail 'conflict is not actionable'
  grep -Fq 'old customization' "$project/.riprap/skills/rr-plan/local.md" ||
    fail 'old customization changed during conflict handling'
  grep -Fq 'new customization' "$project/.riprap/user/skills/rr-plan/local.md" ||
    fail 'new customization changed during conflict handling'
)

# rq-8b0a20e7
test_ignore_rules_distinguish_machine_and_project_state() (
  local project="$1"
  git -C "$project" init --quiet
  mkdir -p "$project/.riprap/state/podman"
  printf '00000000-0000-4000-8000-000000000000\n' > "$project/.riprap/state/project-id"
  : > "$project/.riprap/state/podman/agent-build.env"
  git -C "$project" check-ignore -q .riprap/state/podman/agent-build.env ||
    fail 'machine-local build state is not ignored'
  ! git -C "$project" check-ignore -q .riprap/state/project-id ||
    fail 'shared project identity is ignored'
)

# rq-d0c2c83d
test_ownership_layout_has_no_symbolic_links() (
  local project="$1"
  test -z "$(find "$project" -type l -print -quit)" || fail 'rendered ownership layout uses a symlink'
)

# rq-9045b67e
test_direct_component_directories_are_absent() (
  local project="$1" name
  for name in skills hooks podman; do
    test ! -e "$project/.riprap/$name" || fail "parallel canonical path exists: .riprap/$name"
  done
)

main() {
  local temp project
  temp="$(mktemp -d)"; trap "rm -rf '$temp'" EXIT
  project="$temp/project"
  render_project "$project"
  test_rendered_project_separates_ownership_classes "$project"
  test_conventional_project_content_remains_user_owned "$project"
  test_root_launchers_are_managed_adapters "$project"
  test_unapproved_managed_exception_is_rejected "$project"
  test_layout_migration_preserves_existing_customizations
  test_layout_migration_rejects_conflicting_customizations
  test_ignore_rules_distinguish_machine_and_project_state "$project"
  test_ownership_layout_has_no_symbolic_links "$project"
  test_direct_component_directories_are_absent "$project"
  printf 'PASS: template ownership layout\n'
}

main "$@"
