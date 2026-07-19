#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The literal token that makes a managed file's ownership visible from the file itself.
MARKER='Riprap-managed'
# A marker may follow an interpreter directive or a tool-mandated header block (a shebang, or the
# YAML frontmatter that agents require at the top of a skill adapter), so it is not always line 1.
MARKER_LINES=15

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

render_project() {
  copier copy --trust --defaults --vcs-ref HEAD \
    --data project_name='Ownership Test' --data project_slug='ownership-test' \
    --data project_description='Exercises rendered ownership classes' \
    --data language="${2:-rust}" --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' --data open_source_license=MIT \
    "$ROOT" "$1" >/dev/null
}

# Mutating tests work on a throwaway copy so they cannot perturb later tests.
copy_project() {
  local dest="$2"
  cp -a "$1" "$dest"
  printf '%s' "$dest"
}

# Approved required-location exceptions, held as parallel arrays.
EXC_PATTERN=()
EXC_EXEMPT=()

# rq-12165531
load_exceptions() {
  local project="$1" line pattern flag
  EXC_PATTERN=()
  EXC_EXEMPT=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    read -r pattern flag <<<"$line"
    [[ -z "$flag" || "$flag" == marker-exempt ]] ||
      fail "unknown ownership-exceptions flag '$flag' for $pattern"
    EXC_PATTERN+=("$pattern")
    EXC_EXEMPT+=("$flag")
  done < "$project/.riprap/managed/ownership-exceptions"
}

# Sets EXC_MATCH_EXEMPT and returns 0 when $1 is an approved exception.
is_approved_exception() {
  local path="$1" i pattern
  EXC_MATCH_EXEMPT=
  for i in "${!EXC_PATTERN[@]}"; do
    pattern="${EXC_PATTERN[$i]}"
    case "$pattern" in
      */'**') [[ "$path" == "${pattern%/**}/"* ]] || continue ;;
      *) [[ "$path" == "$pattern" ]] || continue ;;
    esac
    EXC_MATCH_EXEMPT="${EXC_EXEMPT[$i]}"
    return 0
  done
  return 1
}

# Whether a path's format has comment syntax that can carry the marker.
can_express_comments() {
  case "$1" in
    *.json) return 1 ;;
    *) return 0 ;;
  esac
}

has_marker() {
  head -n "$MARKER_LINES" "$1" 2>/dev/null | grep -Fq "$MARKER"
}

# rq-f9576090 rq-12165531
# A managed file outside .riprap/managed must be approved, and every approved exception must make
# its ownership visible. The two directions together keep the marker and the exception list from
# drifting apart.
check_exception_ownership() {
  local project="$1" path file
  while IFS= read -r -d '' file; do
    path="${file#"$project"/}"
    case "$path" in
      .riprap/managed/*|.riprap/user/*|.riprap/state/*) continue ;;
    esac
    if is_approved_exception "$path"; then
      if [[ "$EXC_MATCH_EXEMPT" == marker-exempt ]]; then
        can_express_comments "$path" &&
          fail "marker-exempt is only for comment-less formats: $path"
      elif ! has_marker "$file"; then
        fail "approved managed exception carries no '$MARKER' marker: $path"
      fi
    elif has_marker "$file"; then
      fail "managed path outside .riprap/managed is not approved: $path"
    fi
  done < <(find "$project" -type f -print0)
}

# rq-f9576090
# Every .riprap path a rendered file names must belong to the ownership layout, and a managed
# reference must resolve. References under user/ and state/ name files a project or a launch
# creates, so they are not existence-checked.
check_riprap_references() {
  local project="$1" file path ref
  while IFS= read -r file; do
    path="${file#"$project"/}"
    while IFS= read -r ref; do
      case "$ref" in
        .riprap/managed|.riprap/user|.riprap/state) continue ;;
        .riprap/user/*|.riprap/state/*) continue ;;
        .riprap/managed/*)
          test -e "$project/$ref" ||
            fail "$path references a missing managed path: $ref"
          ;;
        *) fail "$path references an undefined component directory: $ref" ;;
      esac
    done < <(grep -oE '\.riprap/[A-Za-z0-9_./-]+' "$file" |
      sed 's/[.,:;)]*$//' | sort -u)
  done < <(grep -rIl '\.riprap/' "$project" --exclude-dir=.git)
}

validate_project() {
  load_exceptions "$1"
  check_exception_ownership "$1"
  check_riprap_references "$1"
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
  for path in README.md LICENSE Containerfile Cargo.toml src/lib.rs CLAUDE.md AGENTS.md; do
    test -f "$project/$path" || fail "conventional user-owned path is missing: $path"
  done
  load_exceptions "$project"
  # Workflows are project-owned: a project chooses its own CI steps, scan languages, query
  # suites, and schedule, so neither is claimed as a managed exception.
  for path in CLAUDE.md AGENTS.md .github/workflows/CI.yaml .github/workflows/codeql.yaml; do
    test -f "$project/$path" || fail "conventional user-owned path is missing: $path"
    ! is_approved_exception "$path" ||
      fail "user-owned file is claimed as a managed exception: $path"
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
  local temp project output
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$(copy_project "$1" "$temp/project")"
  mkdir -p "$project/.github"
  printf '# Riprap-managed test file\n' > "$project/.github/unapproved.sh"
  ! output="$(validate_project "$project" 2>&1)" || fail 'unapproved managed exception was accepted'
  grep -Fq '.github/unapproved.sh' <<<"$output" || fail 'unapproved path was not identified'
)

# rq-64f745b6
test_exception_without_marker_is_rejected() (
  local temp project output
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$(copy_project "$1" "$temp/project")"
  grep -v "$MARKER" "$project/.gitattributes" > "$project/.gitattributes.stripped"
  mv "$project/.gitattributes.stripped" "$project/.gitattributes"
  ! output="$(validate_project "$project" 2>&1)" || fail 'unmarked approved exception was accepted'
  grep -Fq '.gitattributes' <<<"$output" || fail 'unmarked path was not identified'
)

# rq-23cdd66f
test_marker_exempt_exception_needs_no_marker() (
  local project="$1"
  load_exceptions "$project"
  is_approved_exception .claude/settings.json || fail 'settings.json is not an approved exception'
  test "$EXC_MATCH_EXEMPT" = marker-exempt || fail 'settings.json is not marker-exempt'
  ! has_marker "$project/.claude/settings.json" || fail 'test premise: settings.json carries a marker'
  validate_project "$project"
)

# rq-23cdd66f
test_marker_exempt_is_rejected_for_commentable_format() (
  local temp project output
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$(copy_project "$1" "$temp/project")"
  sed -i 's|^\.gitattributes$|.gitattributes\tmarker-exempt|' \
    "$project/.riprap/managed/ownership-exceptions"
  grep -q 'marker-exempt' <<<"$(grep '^\.gitattributes' \
    "$project/.riprap/managed/ownership-exceptions")" || fail 'test premise: exempt flag not applied'
  ! output="$(validate_project "$project" 2>&1)" ||
    fail 'marker-exempt was accepted for a commentable format'
  grep -Fq 'comment-less formats' <<<"$output" || fail 'exempt misuse is not actionable'
)

# rq-215e96be
test_undefined_component_directory_reference_is_rejected() (
  local temp project output
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$(copy_project "$1" "$temp/project")"
  printf 'run: .riprap/hooks/check-secrets.sh --repository\n' >> "$project/.github/workflows/CI.yaml"
  ! output="$(validate_project "$project" 2>&1)" ||
    fail 'reference to an undefined component directory was accepted'
  grep -Fq '.riprap/hooks' <<<"$output" || fail 'undefined path was not identified'
  grep -Fq '.github/workflows/CI.yaml' <<<"$output" || fail 'referencing file was not identified'
)

# rq-f3bedd31
test_missing_managed_reference_is_rejected() (
  local temp project output
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  project="$(copy_project "$1" "$temp/project")"
  rm "$project/.riprap/managed/hooks/check-secrets.sh"
  ! output="$(validate_project "$project" 2>&1)" ||
    fail 'reference to a missing managed implementation was accepted'
  grep -Fq '.riprap/managed/hooks/check-secrets.sh' <<<"$output" ||
    fail 'unresolved path was not identified'
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

# rq-602c57d1
# The managed region precedes the project-owned one so that a managed rule change and a project's
# own additions never touch the same lines. Without that ordering copier reports a conflict on
# every update that follows a project adding an ignore rule.
test_project_ignore_rules_survive_managed_update() (
  local temp source project ignore
  temp="$(mktemp -d)"; trap 'rm -rf "$temp"' EXIT
  source="$temp/source"
  project="$temp/project"

  cp -a "$ROOT/." "$source/"
  rm -rf "$source/.git"
  git -C "$source" init --quiet
  git -C "$source" config user.name 'Riprap Tests'
  git -C "$source" config user.email 'riprap@example.com'
  git -C "$source" add .
  git -C "$source" commit --quiet -m 'template v1'
  git -C "$source" tag v1.0.0

  copier copy --trust --defaults --vcs-ref v1.0.0 \
    --data project_name='Ignore Test' --data project_slug='ignore-test' \
    --data project_description='Exercises ignore-region ownership' \
    --data language=rust --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' --data open_source_license=MIT \
    "$source" "$project" >/dev/null
  ignore="$project/.gitignore"
  printf '/scratch/\n*.bin\n' >> "$ignore"
  git -C "$project" init --quiet
  git -C "$project" config user.name 'Riprap Tests'
  git -C "$project" config user.email 'riprap@example.com'
  git -C "$project" add .
  git -C "$project" commit --quiet -m 'generated project with its own ignore rules'

  # A managed-region change of the kind this file has historically received.
  sed -i 's|^/\.env\.\*\.local$|/.env.*.local\n/.newagent/auth.json|' \
    "$source/template/.gitignore.jinja"
  git -C "$source" add template/.gitignore.jinja
  git -C "$source" commit --quiet -m 'template v2'
  git -C "$source" tag v2.0.0

  copier update --trust --defaults --vcs-ref v2.0.0 "$project" >/dev/null

  grep -Fq '/scratch/' "$ignore" || fail 'project ignore rule was lost by the update'
  grep -Fq '*.bin' "$ignore" || fail 'project ignore rule was lost by the update'
  grep -Fq '/.newagent/auth.json' "$ignore" || fail 'managed ignore rule did not propagate'
  ! grep -q '<<<<<<<' "$ignore" || fail 'ignore-file update produced a merge conflict'
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
  local temp project language
  temp="$(mktemp -d)"; trap "rm -rf '$temp'" EXIT

  # Ownership and reference rules must hold for every rendered variant, not just the default.
  for language in rust python; do
    project="$temp/$language"
    render_project "$project" "$language"
    load_exceptions "$project"
    validate_project "$project"
  done

  project="$temp/rust"
  test_rendered_project_separates_ownership_classes "$project"
  test_conventional_project_content_remains_user_owned "$project"
  test_root_launchers_are_managed_adapters "$project"
  test_unapproved_managed_exception_is_rejected "$project"
  test_exception_without_marker_is_rejected "$project"
  test_marker_exempt_exception_needs_no_marker "$project"
  test_marker_exempt_is_rejected_for_commentable_format "$project"
  test_undefined_component_directory_reference_is_rejected "$project"
  test_missing_managed_reference_is_rejected "$project"
  test_layout_migration_preserves_existing_customizations
  test_layout_migration_rejects_conflicting_customizations
  test_project_ignore_rules_survive_managed_update
  test_ignore_rules_distinguish_machine_and_project_state "$project"
  test_ownership_layout_has_no_symbolic_links "$project"
  test_direct_component_directories_are_absent "$project"
  printf 'PASS: template ownership layout\n'
}

main "$@"
