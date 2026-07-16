#!/usr/bin/env bash
# tests/test_rqm.sh — agent-neutral tests for rqm.sh (one test per Gherkin scenario)
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/rqm.sh"
PASS=0; FAIL=0; ERRORS=()

# ── framework ─────────────────────────────────────────────────────────────────

# Each test function receives a fresh temp dir as CWD.
run_test() {
  local name="$1" fn="$2"
  local td; td=$(mktemp -d)
  mkdir -p "$td/rqm" "$td/src"
  local rc=0
  (
    export RQM_DIR="rqm" SRC_DIR="src"
    cd "$td"
    "$fn"
  ) || rc=$?
  rm -rf "$td"
  if [[ $rc -eq 0 ]]; then
    printf 'PASS  %s\n' "$name"
    (( PASS++ )) || true
  else
    printf 'FAIL  %s\n' "$name"
    ERRORS+=("$name")
    (( FAIL++ )) || true
  fi
}

rqm() { bash "$SCRIPT" "$@"; }

assert() {
  local msg="$1"; shift
  if ! "$@" > /dev/null 2>&1; then
    echo "  ASSERT FAILED: $msg" >&2; exit 1
  fi
}

assert_match() { assert "output matches /$1/" grep -qE "$1" <<< "$2"; }
assert_file_contains() { assert "file $1 contains /$2/" grep -qE "$2" "$1"; }
assert_file_not_contains() {
  if grep -qE "$2" "$1" 2>/dev/null; then
    echo "  ASSERT FAILED: file $1 does not contain /$2/" >&2; exit 1
  fi
}
assert_eq() { [[ "$1" == "$2" ]] || { echo "  ASSERT: '$1' != '$2'" >&2; exit 1; }; }
assert_exit_nonzero() { [[ $1 -ne 0 ]] || { echo "  ASSERT: expected non-zero exit" >&2; exit 1; }; }

# ── stamp: headings ───────────────────────────────────────────────────────────

t_stamp_adds_id_to_heading() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Feature API
EOF
  rqm stamp rqm/test.md
  assert_file_contains rqm/test.md '## Feature API <!-- rq-[0-9a-f]{8} -->'
}

t_stamp_does_not_change_existing_id() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-3a7f1c2e -->
## Feature API <!-- rq-3a7f1c2e -->
EOF
  # pre-load so no collision
  rqm stamp rqm/test.md
  assert_file_contains rqm/test.md '## Feature API <!-- rq-3a7f1c2e -->'
}

t_stamp_adds_id_to_file_level_heading() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
EOF
  rqm stamp rqm/test.md
  assert_file_contains rqm/test.md '# Feature: Test <!-- rq-[0-9a-f]{8} -->'
}

# ── stamp: API items ──────────────────────────────────────────────────────────

t_stamp_adds_id_to_api_bullet() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Feature API
- `my_fn()` does stuff
EOF
  rqm stamp rqm/test.md
  assert_file_contains rqm/test.md '`my_fn\(\)` does stuff <!-- rq-[0-9a-f]{8} -->'
}

t_stamp_skips_sub_bullet() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Feature API
- `my_fn()` does stuff
  - `SubError` — a sub variant
EOF
  rqm stamp rqm/test.md
  assert_file_not_contains rqm/test.md '`SubError`.*<!--'
}

t_stamp_skips_bullet_outside_api() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Background
- `some_note` about stuff
## Feature API
- `my_fn()` does stuff
EOF
  rqm stamp rqm/test.md
  assert_file_not_contains rqm/test.md '`some_note`.*<!--'
}

# ── stamp: Gherkin scenarios ──────────────────────────────────────────────────

t_stamp_adds_gherkin_tag() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Gherkin Scenarios
```gherkin
Feature: X
  Scenario: first test
    Given something
```
EOF
  rqm stamp rqm/test.md
  assert_file_contains rqm/test.md '@rq-[0-9a-f]{8}'
  # Tag must appear before Scenario:
  awk '/Scenario:/{ if (previous !~ /@rq-/) exit 1 } { previous=$0 }' rqm/test.md
}

t_stamp_does_not_change_tagged_scenario() {
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Gherkin Scenarios
```gherkin
Feature: X
  @rq-7c1e5d3b
  Scenario: first test
    Given something
```
EOF
  rqm stamp rqm/test.md
  assert_file_contains rqm/test.md '@rq-7c1e5d3b'
  # Only one rq- tag for this scenario
  local count; count=$(grep -c '@rq-' rqm/test.md || true)
  assert_eq "$count" "1"
}

# ── stamp: ID uniqueness ──────────────────────────────────────────────────────

t_stamp_no_duplicate_ids() {
  # Stamp a file with multiple entities; verify all IDs are unique
  cat > rqm/test.md <<'EOF'
# Feature: Test
## Feature API
- `fn_a()` does a
- `fn_b()` does b
## Gherkin Scenarios
```gherkin
Feature: X
  Scenario: one
    Given a
  Scenario: two
    Given b
```
EOF
  rqm stamp rqm/test.md
  local count total unique
  count=$(grep -oE 'rq-[0-9a-f]{8}' rqm/test.md | wc -l | tr -d ' ')
  unique=$(grep -oE 'rq-[0-9a-f]{8}' rqm/test.md | sort -u | wc -l | tr -d ' ')
  assert_eq "$count" "$unique"
}

# ── index ─────────────────────────────────────────────────────────────────────

t_index_builds_registry() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
- `my_fn()` does stuff <!-- rq-cccccccc -->
## Gherkin Scenarios
```gherkin
Feature: X
  @rq-dddddddd
  Scenario: first test
    Given something
```
EOF
  rqm index
  assert "[registry.json exists]" test -f rqm/registry.json
  assert_file_contains rqm/registry.json '"rq-aaaaaaaa"'
  assert_file_contains rqm/registry.json '"rq-bbbbbbbb"'
  assert_file_contains rqm/registry.json '"rq-cccccccc"'
  assert_file_contains rqm/registry.json '"rq-dddddddd"'
  # Each entry has a decl field
  assert_file_contains rqm/registry.json '"decl"'
  # Valid JSON
  jq . rqm/registry.json > /dev/null
}

t_index_records_source_ref() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
- `my_fn()` <!-- rq-9b4d2f1a -->
## Gherkin Scenarios
```gherkin
Feature: X
```
EOF
  cat > src/lib.rs <<'EOF'
// rq-9b4d2f1a
pub fn my_fn() {}
EOF
  rqm index
  assert_file_contains rqm/registry.json '"src/lib.rs"'
}

t_index_records_python_source_ref() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
- `my_fn()` <!-- rq-9b4d2f1a -->
## Gherkin Scenarios
```gherkin
Feature: X
```
EOF
  cat > src/lib.py <<'EOF'
# rq-9b4d2f1a
def my_fn(): ...
EOF
  rqm index
  assert_file_contains rqm/registry.json '"src/lib.py"'
}

t_index_deduplicates_refs_from_same_file() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
- `my_fn()` <!-- rq-9b4d2f1a -->
## Gherkin Scenarios
```gherkin
Feature: X
```
EOF
  cat > src/lib.rs <<'EOF'
// rq-9b4d2f1a first
fn a() {}
// rq-9b4d2f1a second
fn b() {}
EOF
  rqm index
  # Should have exactly one ref entry for src/lib.rs
  local count
  count=$(jq '.["rq-9b4d2f1a"].refs | length' rqm/registry.json)
  assert_eq "$count" "1"
}

t_index_records_cross_ref_in_md() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
- `my_fn()` <!-- rq-9b4d2f1a -->
## Gherkin Scenarios
```gherkin
Feature: X
```
EOF
  cat > rqm/other.md <<'EOF'
# Feature: Other <!-- rq-eeeeeeee -->
<!-- rq-9b4d2f1a cross-reference -->
EOF
  rqm index
  local refs
  refs=$(jq -r '.["rq-9b4d2f1a"].refs[].file' rqm/registry.json)
  assert_match 'rqm/other.md' "$refs"
}

t_index_is_idempotent() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
- `my_fn()` <!-- rq-cccccccc -->
## Gherkin Scenarios
```gherkin
Feature: X
```
EOF
  rqm index
  local first; first=$(cat rqm/registry.json)
  rqm index
  local second; second=$(cat rqm/registry.json)
  assert_eq "$first" "$second"
}

t_index_aborts_duplicate_with_stored_decl() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-3a7f1c2e -->
## New Section <!-- rq-3a7f1c2e -->
EOF
  # Write a registry with stored decl for rq-3a7f1c2e
  cat > rqm/registry.json <<'EOF'
{
  "rq-3a7f1c2e": {
    "type": "section",
    "file": "test",
    "title": "Feature API",
    "decl": "## Feature API",
    "refs": []
  }
}
EOF
  local out rc=0
  out=$(rqm index 2>&1) || rc=$?
  assert_exit_nonzero $rc
  assert_match 'likely original' "$out"
  assert_match 'likely copy' "$out"
  assert_match 'stamp --fix-duplicates' "$out"
}

t_index_aborts_duplicate_neither_matches() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Section A <!-- rq-3a7f1c2e -->
## Section B <!-- rq-3a7f1c2e -->
EOF
  cat > rqm/registry.json <<'EOF'
{
  "rq-3a7f1c2e": {
    "type": "section", "file": "test", "title": "Old Section",
    "decl": "## Old Section", "refs": []
  }
}
EOF
  local out rc=0
  out=$(rqm index 2>&1) || rc=$?
  assert_exit_nonzero $rc
  assert_match '[Uu]nresolvable|manually' "$out"
}

t_index_aborts_duplicate_no_registry() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Section A <!-- rq-3a7f1c2e -->
## Section B <!-- rq-3a7f1c2e -->
EOF
  local out rc=0
  out=$(rqm index 2>&1) || rc=$?
  assert_exit_nonzero $rc
  assert_match 'no prior registry' "$out"
  assert_match 'manually' "$out"
}

# ── stamp --fix-duplicates ────────────────────────────────────────────────────

t_fix_duplicates_resolves_copy() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-3a7f1c2e -->
## New Section <!-- rq-3a7f1c2e -->
EOF
  cat > rqm/registry.json <<'EOF'
{
  "rq-3a7f1c2e": {
    "type": "section", "file": "test", "title": "Feature API",
    "decl": "## Feature API", "refs": []
  }
}
EOF
  local out; out=$(rqm stamp --fix-duplicates rqm/test.md)
  assert_match 'FIXED' "$out"
  # Original still has its ID
  assert_file_contains rqm/test.md '## Feature API <!-- rq-3a7f1c2e -->'
  # Copy now has a different ID
  local new_id; new_id=$(grep '## New Section' rqm/test.md | grep -oE 'rq-[0-9a-f]{8}')
  [[ "$new_id" != "rq-3a7f1c2e" ]] || { echo "copy ID was not changed" >&2; exit 1; }
}

t_fix_duplicates_unresolvable() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Section A <!-- rq-3a7f1c2e -->
## Section B <!-- rq-3a7f1c2e -->
EOF
  cat > rqm/registry.json <<'EOF'
{
  "rq-3a7f1c2e": {
    "type": "section", "file": "test", "title": "Old",
    "decl": "## Old Section", "refs": []
  }
}
EOF
  local out rc=0
  out=$(rqm stamp --fix-duplicates rqm/test.md 2>&1) || rc=$?
  assert_exit_nonzero $rc
  assert_match '[Uu]nresolvable' "$out"
  # Neither line was modified
  assert_file_contains rqm/test.md '## Section A <!-- rq-3a7f1c2e -->'
  assert_file_contains rqm/test.md '## Section B <!-- rq-3a7f1c2e -->'
}

t_fix_duplicates_no_registry() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Section A <!-- rq-3a7f1c2e -->
## Section B <!-- rq-3a7f1c2e -->
EOF
  local out rc=0
  out=$(rqm stamp --fix-duplicates rqm/test.md 2>&1) || rc=$?
  assert_exit_nonzero $rc
  assert_match '[Uu]nresolvable' "$out"
}

# ── check ─────────────────────────────────────────────────────────────────────

t_check_passes_clean() {
  cat > rqm/registry.json <<'EOF'
{
  "rq-9b4d2f1a": {
    "type": "api-item", "file": "test", "title": "my_fn",
    "decl": "- `my_fn()`",
    "refs": [{"kind": "code", "file": "src/lib.rs"}]
  }
}
EOF
  cat > src/lib.rs <<'EOF'
// rq-9b4d2f1a
pub fn my_fn() {}
EOF
  rqm check
}

t_check_reports_stale_ref() {
  cat > rqm/registry.json <<'EOF'
{"rq-aabbccdd": {"type":"file","file":"test","title":"T","decl":"# T","refs":[]}}
EOF
  cat > src/lib.rs <<'EOF'
// rq-deadbeef
pub fn x() {}
EOF
  local out rc=0
  out=$(rqm check 2>&1) || rc=$?
  assert_exit_nonzero $rc
  assert_match 'STALE.*rq-deadbeef' "$out"
}

t_check_warns_unreferenced() {
  cat > rqm/registry.json <<'EOF'
{"rq-3a7f1c2e": {"type":"section","file":"test","title":"T","decl":"## T","level":2,"refs":[]}}
EOF
  local out; out=$(rqm check 2>&1 || true)
  assert_match 'WARNING.*rq-3a7f1c2e' "$out"
  # Exit code 0
  rqm check > /dev/null 2>&1 || true
  local rc=0; rqm check > /dev/null 2>&1 || rc=$?
  # rc is ok (warnings don't fail)
  [[ $rc -eq 0 ]] || { echo "check should exit 0 for unreferenced" >&2; exit 1; }
}

# ── clean ─────────────────────────────────────────────────────────────────────

t_clean_removes_deleted_file_entry() {
  cat > rqm/registry.json <<'EOF'
{
  "rq-a3f2b1c7": {
    "type": "file", "file": "basis/old", "title": "Old",
    "decl": "# Old", "refs": []
  }
}
EOF
  # rqm/basis/old.md does NOT exist
  local out; out=$(rqm clean)
  assert_match 'REMOVED.*rq-a3f2b1c7' "$out"
  assert_file_not_contains rqm/registry.json 'rq-a3f2b1c7'
}

t_clean_removes_entry_id_gone_from_md() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-aaaaaaaa -->
## Feature API <!-- rq-bbbbbbbb -->
EOF
  cat > rqm/registry.json <<'EOF'
{
  "rq-9b4d2f1a": {
    "type": "api-item", "file": "test", "title": "fn",
    "decl": "- `fn()`", "refs": []
  }
}
EOF
  # rq-9b4d2f1a not in rqm/test.md
  rqm clean
  assert_file_not_contains rqm/registry.json 'rq-9b4d2f1a'
}

t_clean_removes_stale_ref() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-9b4d2f1a -->
EOF
  cat > rqm/registry.json <<'EOF'
{
  "rq-9b4d2f1a": {
    "type": "file", "file": "test", "title": "T",
    "decl": "# Feature: Test",
    "refs": [{"kind":"code","file":"src/lib.rs"}]
  }
}
EOF
  # src/lib.rs does NOT exist (or doesn't contain the ID)
  rqm clean
  # Entry retained but ref removed
  assert_file_contains rqm/registry.json 'rq-9b4d2f1a'
  local ref_count; ref_count=$(jq '.["rq-9b4d2f1a"].refs | length' rqm/registry.json)
  assert_eq "$ref_count" "0"
}

t_clean_preserves_valid_ref() {
  cat > rqm/test.md <<'EOF'
# Feature: Test <!-- rq-9b4d2f1a -->
EOF
  cat > src/lib.rs <<'EOF'
// rq-9b4d2f1a
pub fn x() {}
EOF
  cat > rqm/registry.json <<'EOF'
{
  "rq-9b4d2f1a": {
    "type": "file", "file": "test", "title": "T",
    "decl": "# Feature: Test",
    "refs": [{"kind":"code","file":"src/lib.rs"}]
  }
}
EOF
  rqm clean
  local ref_count; ref_count=$(jq '.["rq-9b4d2f1a"].refs | length' rqm/registry.json)
  assert_eq "$ref_count" "1"
}

# ── run all ───────────────────────────────────────────────────────────────────

tests=(
  t_stamp_adds_id_to_heading
  t_stamp_does_not_change_existing_id
  t_stamp_adds_id_to_file_level_heading
  t_stamp_adds_id_to_api_bullet
  t_stamp_skips_sub_bullet
  t_stamp_skips_bullet_outside_api
  t_stamp_adds_gherkin_tag
  t_stamp_does_not_change_tagged_scenario
  t_stamp_no_duplicate_ids
  t_index_builds_registry
  t_index_records_source_ref
  t_index_records_python_source_ref
  t_index_deduplicates_refs_from_same_file
  t_index_records_cross_ref_in_md
  t_index_is_idempotent
  t_index_aborts_duplicate_with_stored_decl
  t_index_aborts_duplicate_neither_matches
  t_index_aborts_duplicate_no_registry
  t_fix_duplicates_resolves_copy
  t_fix_duplicates_unresolvable
  t_fix_duplicates_no_registry
  t_check_passes_clean
  t_check_reports_stale_ref
  t_check_warns_unreferenced
  t_clean_removes_deleted_file_entry
  t_clean_removes_entry_id_gone_from_md
  t_clean_removes_stale_ref
  t_clean_preserves_valid_ref
)

echo "Running ${#tests[@]} tests..."
for t in "${tests[@]}"; do run_test "$t" "$t"; done

echo ""
echo "${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do echo "  $e"; done
  exit 1
fi
