#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
case "$mode" in --staged|--repository) ;; *) echo 'usage: check-secrets.sh <--staged|--repository>' >&2; exit 2 ;; esac

die() { printf 'secret scan failed: %s\n' "$*" >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die 'current directory is not inside a Git working tree'
cd "$repo_root"

failed=0
scan_blob() {
    local path="$1" blob="$2" category
    case "$path" in
        .codex/auth.json|.claude/.credentials.json|.claude.json|.opencode/data/opencode/auth.json) category='known credential path' ;;
        .env|.env.local|.env.*.local) category='local environment secrets' ;;
        *) category='' ;;
    esac
    if [[ -n "$category" ]]; then printf 'secret rejected: %s (%s)\n' "$path" "$category" >&2; failed=1; fi
    if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$blob"; then
        printf 'secret rejected: %s (private key)\n' "$path" >&2; failed=1
    fi
    if grep -Eq -- '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,})' "$blob"; then
        printf 'secret rejected: %s (supported access token)\n' "$path" >&2; failed=1
    fi
}

paths_file=$(mktemp)
blob_file=$(mktemp)
trap 'rm -f "$paths_file" "$blob_file"' EXIT HUP INT TERM

if [[ "$mode" == --staged ]]; then
    git diff --cached --name-only --diff-filter=ACMRT -z >"$paths_file" ||
        die 'could not enumerate staged paths'
else
    git ls-tree -r --name-only -z HEAD >"$paths_file" ||
        die 'could not enumerate repository paths at HEAD'
fi

while IFS= read -r -d '' path; do
    if [[ "$mode" == --staged ]]; then object=":$path"; else object="HEAD:$path"; fi
    git show "$object" >"$blob_file" 2>/dev/null ||
        die "could not read Git object for path '$path'"
    scan_blob "$path" "$blob_file"
done <"$paths_file"

exit "$failed"
