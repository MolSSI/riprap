#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

render_project() {
  local source="$1" destination="$2"
  copier copy --trust --defaults --vcs-ref HEAD \
    --data project_name='Riprap Test' \
    --data project_slug='riprap-test' \
    --data project_description='Exercises the Riprap template' \
    --data language='rust' \
    --data include_rust_skeleton=false \
    --data author_name='Riprap Tests' \
    --data author_email='riprap@example.com' \
    --data open_source_license='Not Open Source' \
    "$source" "$destination"
}

# rq-217d25aa
test_generated_project_uses_agent_neutral_layout() (
  local temp project skill adapter unexpected
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
  project="$temp/project"

  render_project "$ROOT" "$project"

  for skill in rr-architecture rr-implement rr-plan rr-quiz; do
    test -f "$project/.riprap/managed/skills/$skill/SKILL.md" || \
      fail "generated project lacks canonical $skill implementation"
    for adapter in .claude .agents; do
      test -f "$project/$adapter/skills/$skill/SKILL.md" || \
        fail "generated project lacks $adapter adapter for $skill"
    done
  done

  unexpected="$(find "$project/.claude/skills" "$project/.agents/skills" \
    -type f ! -name SKILL.md -print -quit)"
  test -z "$unexpected" || \
    fail "agent-specific directory contains duplicated canonical resource: $unexpected"
)

# rq-df3907ad rq-e558bda9
test_skill_customization_survives_copier_update() (
  local temp source project local_file canonical_file
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
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

  render_project "$source" "$project"
  local_file="$project/.riprap/user/skills/rr-plan/local.md"
  canonical_file="$project/.riprap/managed/skills/rr-plan/SKILL.md"
  printf '\nuser-local-marker\n' >> "$local_file"
  git -C "$project" init --quiet
  git -C "$project" config user.name 'Riprap Tests'
  git -C "$project" config user.email 'riprap@example.com'
  git -C "$project" add .
  git -C "$project" commit --quiet -m 'generated project with local customization'

  printf '\ntemplate-v2-marker\n' >> \
    "$source/template/.riprap/managed/skills/rr-plan/SKILL.md.jinja"
  git -C "$source" add template/.riprap/managed/skills/rr-plan/SKILL.md.jinja
  git -C "$source" commit --quiet -m 'template v2'
  git -C "$source" tag v2.0.0

  copier update --trust --defaults --vcs-ref v2.0.0 "$project"

  grep -Fq 'user-local-marker' "$local_file" || \
    fail "Copier update overwrote the user's local skill customization"
  grep -Fq 'template-v2-marker' "$canonical_file" || \
    fail "Copier update did not update the canonical skill implementation"
)

test_generated_project_uses_agent_neutral_layout
test_skill_customization_survives_copier_update
printf 'PASS: agent-neutral skills render and update correctly\n'
