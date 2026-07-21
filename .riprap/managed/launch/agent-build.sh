#!/bin/sh
# Manage candidate and successful agent build keys without sourcing untrusted data.

set -eu

key_file=.riprap/state/container/agent-build.env
candidate_file=.riprap/state/container/agent-build.candidate.env
pin_file=.riprap/user/agent-pin.env
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'

die() { printf 'Riprap: %s\n' "$*" >&2; exit 1; }

# The ISO-8601 week-year and week. Both launchers must agree on this stamp, so it is
# exposed as an action that reports the stamp for any date rather than only for today.
iso_week() {
    # Normal launches use only date options shared by Linux and macOS.
    if [ "$#" -eq 0 ] || [ "$1" = now ]; then
        date -u +%G-W%V
    else
        date -u -d "$1" +%G-W%V
    fi
}

prepare() {
    mkdir -p .riprap/state/container
    claude_version=latest
    codex_version=latest
    opencode_version=latest
    refresh="$(iso_week)"

    if [ -e "$pin_file" ]; then
        [ -f "$pin_file" ] && [ ! -L "$pin_file" ] || die "$pin_file must be a regular file"
        seen=0
        seen_claude=0
        seen_codex=0
        seen_opencode=0
        while IFS= read -r raw || [ -n "$raw" ]; do
            line=$(printf '%s' "$raw" | tr -d '\r')
            [ -n "$line" ] || die "$pin_file contains a malformed line: '$line'"
            case "$line" in
                *=*) name=${line%%=*}; value=${line#*=} ;;
                *) die "$pin_file contains a malformed line: '$line'" ;;
            esac
            # Checks run in a fixed precedence so that every launcher reports the same defect
            # for the same file: structure, then name, then repetition, then value.
            case "$name" in
                CLAUDE_VERSION)
                    [ "$seen_claude" -eq 0 ] || die "$pin_file contains duplicate CLAUDE_VERSION assignments" ;;
                CODEX_VERSION)
                    [ "$seen_codex" -eq 0 ] || die "$pin_file contains duplicate CODEX_VERSION assignments" ;;
                OPENCODE_VERSION)
                    [ "$seen_opencode" -eq 0 ] || die "$pin_file contains duplicate OPENCODE_VERSION assignments" ;;
                *) die "$pin_file contains unknown assignment '$name'" ;;
            esac
            [ -n "$value" ] || die "$pin_file: $name has an empty value"
            printf '%s' "$value" | grep -Eq "$version_pattern" ||
                die "$pin_file: $name must be an exact release version such as 1.2.3, but is '$value'"
            case "$name" in
                CLAUDE_VERSION) claude_version=$value; seen_claude=1 ;;
                CODEX_VERSION) codex_version=$value; seen_codex=1 ;;
                OPENCODE_VERSION) opencode_version=$value; seen_opencode=1 ;;
            esac
            seen=$((seen + 1))
        done < "$pin_file"
        [ "$seen" -gt 0 ] || die "$pin_file is empty"
        if [ "$seen_claude" -eq 1 ] && [ "$seen_codex" -eq 1 ] && [ "$seen_opencode" -eq 1 ]; then refresh=pinned; fi
    fi

    tmp=$candidate_file.tmp.$$
    trap 'rm -f "$tmp"' EXIT HUP INT TERM
    printf 'CLAUDE_VERSION=%s\nCODEX_VERSION=%s\nOPENCODE_VERSION=%s\nREFRESH=%s\n' \
        "$claude_version" "$codex_version" "$opencode_version" "$refresh" > "$tmp"
    mv "$tmp" "$candidate_file"
    trap - EXIT HUP INT TERM
}

case "${1:-prepare}" in
    prepare) prepare ;;
    promote)
        [ -f "$candidate_file" ] || die 'no agent build candidate exists'
        [ "${2:-}" ] && [ "${3:-}" ] && [ "${4:-}" ] ||
            die 'promote requires exact Claude, Codex, and OpenCode versions'
        tmp=$candidate_file.promote.$$
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        sed '/^INSTALLED_/d' "$candidate_file" > "$tmp"
        printf 'INSTALLED_CLAUDE_VERSION=%s\nINSTALLED_CODEX_VERSION=%s\nINSTALLED_OPENCODE_VERSION=%s\n' \
            "$2" "$3" "$4" >> "$tmp"
        mv "$tmp" "$key_file"
        rm -f "$candidate_file"
        trap - EXIT HUP INT TERM ;;
    discard) rm -f "$candidate_file" ;;
    week) iso_week "${2:-now}" ;;
    *) die "unknown agent build action '$1'" ;;
esac
