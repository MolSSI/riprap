#!/bin/sh

image="${1:-$(cat .riprap/podman/image_name)}"
project_id="${2:?project UUID is required}"

mount_pwd="$(pwd)"

# Inside WSL, if `podman` resolves to the Windows-side binary, the volume
# mounts must use Windows paths -- podman.exe cannot read WSL paths directly.
if grep -qi microsoft /proc/version 2>/dev/null; then
    podman_path="$(command -v podman)"
    case "$podman_path" in
        *.exe|/mnt/*)
            mount_pwd="$(wslpath -w "$mount_pwd")"
            ;;
    esac
fi

run_options_file=".riprap/podman/run-options"

fail() {
    printf 'Riprap: %s\n' "$1" >&2
    exit 1
}

# The project's runtime options become positional parameters, which is how a POSIX shell
# carries a list of arguments without re-quoting it. One argument per line keeps the file
# free of shell quoting rules, so an option reaches the runtime exactly as written.
#
# A line is accepted only as a single whitespace-free argument beginning with "-". Checks
# run in a fixed order -- whitespace, then leading "-" -- so a line with both defects is
# reported identically by every launcher.
set --
if [ -f "$run_options_file" ]; then
    line_number=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        # Remove only the terminal carriage return from a CRLF checkout. An embedded
        # carriage return remains content and is rejected by the whitespace check below.
        option="$(printf '%s' "$line" | sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$option" in
            ''|'#'*) continue ;;
        esac
        case "$option" in
            *[[:space:]]*)
                fail "${run_options_file} line ${line_number}: an option must be a single argument with no spaces: ${option}" ;;
        esac
        case "$option" in
            -*) ;;
            *) fail "${run_options_file} line ${line_number}: an option must begin with '-': ${option}" ;;
        esac
        set -- "$@" "$option"
    done < "$run_options_file"
fi

# Claude stores its top-level configuration file (.claude.json), which records the
# authenticated account and onboarding state, outside its credential directory by
# default. Point CLAUDE_CONFIG_DIR at the mounted Claude volume so that both the
# configuration file and the credentials persist across removal of this container.
#
# The volumes below hold credentials and session state only. Both agents' programs
# live in the agent image at versions recorded in its labels and successful build key,
# and the image disables their self-updaters, so a session runs the recorded versions.
#
# The project's options follow, so a runtime that resolves a repeated option in favor of
# its last occurrence resolves it in the project's favor.
podman run --rm -it \
    -v "${mount_pwd}:/work" \
    -v "riprap-${project_id}-claude:/root/.claude" \
    -v "riprap-${project_id}-codex:/root/.codex" \
    -e CLAUDE_CONFIG_DIR=/root/.claude \
    -w /work \
    "$@" \
    "$image" \
    bash
