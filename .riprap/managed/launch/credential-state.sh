#!/bin/sh
set -eu

id_file=.riprap/state/project-id
uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

die() {
    printf 'Riprap: %s\n' "$*" >&2
    exit 1
}

validate_id() {
    [ ! -L "$id_file" ] || die "$id_file must not be a symbolic link"
    [ -f "$id_file" ] || die "$id_file must be a regular file"
    project_id=$(cat "$id_file")
    lines=$(wc -l < "$id_file" | tr -d ' ')
    [ "$lines" = 1 ] && printf '%s\n' "$project_id" | grep -Eq "$uuid_pattern" || \
        die "$id_file must contain one canonical lowercase UUID"
}

create_id() {
    mkdir -p .riprap/state
    if [ -e "$id_file" ] || [ -L "$id_file" ]; then
        return 0
    fi
    lock=$id_file.lock
    if mkdir "$lock" 2>/dev/null; then
        trap 'rm -rf "$lock" "$id_file.tmp.$$"' EXIT HUP INT TERM
        if [ ! -e "$id_file" ] && [ ! -L "$id_file" ]; then
            hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
            project_id=$(printf '%s\n' "$hex" | awk '{printf "%s-%s-4%s-%x%s-%s\n", substr($0,1,8), substr($0,9,4), substr($0,14,3), (strtonum("0x" substr($0,17,1)) % 4) + 8, substr($0,18,3), substr($0,21,12)}' 2>/dev/null) || true
            if ! printf '%s\n' "$project_id" | grep -Eq "$uuid_pattern"; then
                # POSIX awk implementations need no hexadecimal conversion for this fallback.
                variant=$(printf '%s' "$hex" | cut -c17 | tr '0123456789abcdef' '89ab89ab89ab89ab')
                project_id="$(printf '%s' "$hex" | cut -c1-8)-$(printf '%s' "$hex" | cut -c9-12)-4$(printf '%s' "$hex" | cut -c14-16)-${variant}$(printf '%s' "$hex" | cut -c18-20)-$(printf '%s' "$hex" | cut -c21-32)"
            fi
            (umask 022; printf '%s\n' "$project_id" > "$id_file.tmp.$$")
            mv "$id_file.tmp.$$" "$id_file"
        fi
        rm -rf "$lock"
        trap - EXIT HUP INT TERM
    else
        count=0
        while [ -d "$lock" ] && [ "$count" -lt 50 ]; do
            sleep 0.1
            count=$((count + 1))
        done
        [ ! -d "$lock" ] || die "timed out waiting for project identity creation"
    fi
}

volume_name() {
    printf 'riprap-%s-%s\n' "$project_id" "$1"
}

ensure() {
    create_id
    validate_id
    for agent in claude codex; do
        volume=$(volume_name "$agent")
        podman volume inspect "$volume" >/dev/null 2>&1 || podman volume create "$volume" >/dev/null
    done
    printf '%s\n' "$project_id"
}

reset() {
    agent=${1:-}
    confirmation=${2:-}
    case "$agent" in claude|codex|all) ;; *) die 'usage: rr.sh --reset-agent-state <claude|codex|all> [--yes]' ;; esac
    validate_id
    if [ "$agent" = all ]; then agents='claude codex'; else agents=$agent; fi
    printf 'Riprap will remove credential state volumes:\n'
    for selected in $agents; do printf '  %s\n' "$(volume_name "$selected")"; done
    if [ "$confirmation" != --yes ]; then
        [ -t 0 ] || die 'confirmation requires a terminal; pass --yes for non-interactive use'
        printf 'Continue? [y/N] '
        read -r answer
        case "$answer" in y|Y|yes|YES) ;; *) die 'reset cancelled' ;; esac
    fi
    for selected in $agents; do podman volume rm "$(volume_name "$selected")" >/dev/null; done
}

install_hooks() {
    git rev-parse --show-toplevel >/dev/null 2>&1 || die 'run this command inside a Git repository'
    current=$(git config --local --get core.hooksPath || true)
    if [ -n "$current" ] && [ "$current" != .riprap/managed/hooks ]; then
        die "core.hooksPath is already '$current'; leave it unchanged and compose that hook with .riprap/managed/hooks/check-secrets.sh --staged"
    fi
    git config --local core.hooksPath .riprap/managed/hooks
    printf 'Riprap Git hooks installed.\n'
}

case "${1:-}" in
    ensure) ensure ;;
    reset) shift; reset "$@" ;;
    install-hooks) install_hooks ;;
    *) die 'expected ensure, reset, or install-hooks' ;;
esac
