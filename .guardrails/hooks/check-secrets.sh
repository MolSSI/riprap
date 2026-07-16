#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
case "$mode" in --staged|--repository) ;; *) echo 'usage: check-secrets.sh <--staged|--repository>' >&2; exit 2 ;; esac

failed=0
scan_blob() {
    local path="$1" content="$2" category
    case "$path" in
        .codex/auth.json|.claude/.credentials.json|.claude.json) category='known credential path' ;;
        .env|.env.local|.env.*.local) category='local environment secrets' ;;
        *) category='' ;;
    esac
    if [[ -n "$category" ]]; then printf 'secret rejected: %s (%s)\n' "$path" "$category" >&2; failed=1; fi
    if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' <<<"$content"; then
        printf 'secret rejected: %s (private key)\n' "$path" >&2; failed=1
    fi
    if grep -Eq -- '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,})' <<<"$content"; then
        printf 'secret rejected: %s (supported access token)\n' "$path" >&2; failed=1
    fi
}

while IFS= read -r -d '' path; do
    if [[ "$mode" == --staged ]]; then
        content=$(git show ":$path" 2>/dev/null || true)
    else
        content=$(git show "HEAD:$path" 2>/dev/null || true)
    fi
    scan_blob "$path" "$content"
done < <(if [[ "$mode" == --staged ]]; then git diff --cached --name-only --diff-filter=ACMR -z; else git ls-tree -r --name-only -z HEAD; fi)

exit "$failed"
