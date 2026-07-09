#!/usr/bin/env bash
# check-skill-sync.sh [--fix]
#
# Verify that the live skills under .claude/skills/ (used when developing this
# repository) match the skills the template ships under template/.claude/skills/.
#
# The template copies are Jinja files rendered by Copier, so the comparison
# renders the template with language=rust (the flavour the dev copies mirror)
# and diffs the result against .claude/skills/. Blank-line differences are
# ignored, because Jinja block tags leave blank lines behind when rendered.
#
# With --fix, any out-of-sync or missing dev copy is overwritten with the
# rendered output. The template is the source of truth: edit files under
# template/.claude/skills/, then use --fix to update the dev copies.
set -euo pipefail

FIX=0
if [[ "${1:-}" == "--fix" ]]; then
  FIX=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--fix]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in copier git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found on PATH" >&2
    [[ "$tool" == copier ]] && echo "hint: pip install copier" >&2
    exit 2
  fi
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Copier renders a template from its committed git state, so build a throwaway
# clone whose single commit is a snapshot of the working tree. This makes the
# check see uncommitted template edits too.
snapshot="$workdir/template"
mkdir -p "$snapshot"
cp -a "$REPO_ROOT/." "$snapshot/"
rm -rf "$snapshot/.git"
git -C "$snapshot" init -q
git -C "$snapshot" add -A
git -C "$snapshot" -c user.name=sync-check -c user.email=sync-check@localhost \
  commit -qm snapshot
# A version tag keeps Copier from warning about an untagged template.
git -C "$snapshot" tag v0.0.0

render="$workdir/render"
copier copy -q --trust --defaults \
  -d project_name="Sync Check" \
  -d project_slug=sync-check \
  -d project_description="Rendered by check-skill-sync.sh" \
  -d language=rust \
  -d author_name="Sync Check" \
  -d author_email=sync-check@localhost \
  "$snapshot" "$render"

dev_skills="$REPO_ROOT/.claude/skills"
rendered_skills="$render/.claude/skills"

# diff -B ignores blank-line-only differences; trailing whitespace is stripped
# on both sides for the same reason.
files_match() {
  diff -Bq <(sed 's/[[:space:]]*$//' "$1") <(sed 's/[[:space:]]*$//' "$2") >/dev/null
}

status=0

while IFS= read -r -d '' rendered; do
  rel="${rendered#"$rendered_skills"/}"
  dev="$dev_skills/$rel"
  if [[ ! -f "$dev" ]]; then
    if [[ $FIX -eq 1 ]]; then
      mkdir -p "$(dirname "$dev")"
      cp -p "$rendered" "$dev"
      echo "FIXED (created): .claude/skills/$rel"
    else
      echo "MISSING dev copy: .claude/skills/$rel"
      status=1
    fi
  elif ! files_match "$rendered" "$dev"; then
    if [[ $FIX -eq 1 ]]; then
      cp -p "$rendered" "$dev"
      echo "FIXED: .claude/skills/$rel"
    else
      echo "OUT OF SYNC: .claude/skills/$rel"
      diff -B <(sed 's/[[:space:]]*$//' "$rendered") <(sed 's/[[:space:]]*$//' "$dev") \
        | sed 's/^/    /' || true
      status=1
    fi
  fi
done < <(find "$rendered_skills" -type f -print0 | sort -z)

# Files that exist only in the dev tree have no template counterpart at all.
while IFS= read -r -d '' dev; do
  rel="${dev#"$dev_skills"/}"
  if [[ ! -f "$rendered_skills/$rel" ]]; then
    echo "EXTRA dev copy (not in template): .claude/skills/$rel"
    status=1
  fi
done < <(find "$dev_skills" -type f -print0 | sort -z)

if [[ $status -eq 0 ]]; then
  echo "skills in sync"
else
  echo ""
  echo "Dev copies differ from the template rendering." >&2
  echo "The template is the source of truth; run '$0 --fix' to update .claude/skills/." >&2
fi
exit $status
