#!/bin/sh

image="${1:-$(cat .riprap/managed/container/image_name)}"
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

run_options_file=".riprap/user/podman/run-options"

# The project's runtime options become positional parameters, which is how a POSIX shell carries a
# list of arguments without re-quoting it. The shared helper validates the file identically for
# every runtime and emits each accepted option on its own line; splitting on newlines alone is safe
# because every accepted option is whitespace-free.
. .riprap/managed/launch/run-options.sh
options="$(emit_run_options "$run_options_file")" || exit 1
set --
IFS='
'
for option in $options; do set -- "$@" "$option"; done
unset IFS

# Claude stores its top-level configuration file (.claude.json), which records the
# authenticated account and onboarding state, outside its credential directory by
# default. Point CLAUDE_CONFIG_DIR at the mounted Claude volume so that both the
# configuration file and the credentials persist across removal of this container.
#
# The volumes below hold credentials and session state only. The agents' programs
# live in the agent image at versions recorded in its labels and successful build key,
# and the image disables their self-updaters, so a session runs the recorded versions.
#
# The project's options follow, so a runtime that resolves a repeated option in favor of
# its last occurrence resolves it in the project's favor.
podman run --rm -it \
    -v "${mount_pwd}:/work" \
    -v "riprap-${project_id}-claude:/opt/riprap/home/.claude" \
    -v "riprap-${project_id}-codex:/opt/riprap/home/.codex" \
    -v "riprap-${project_id}-opencode:/opt/riprap/home/.opencode" \
    -e CLAUDE_CONFIG_DIR=/opt/riprap/home/.claude \
    -w /work \
    "$@" \
    "$image" \
    bash
