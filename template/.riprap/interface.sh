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

# Claude stores its top-level configuration file (.claude.json), which records the
# authenticated account and onboarding state, outside its credential directory by
# default. Point CLAUDE_CONFIG_DIR at the mounted Claude volume so that both the
# configuration file and the credentials persist across removal of this container.
#
# The volumes below hold credentials and session state only. Both agents' programs
# live in the agent image at versions recorded in its labels and successful build key,
# and the image disables their self-updaters, so a session runs the recorded versions.
podman run --rm -it \
    -v "${mount_pwd}:/work" \
    -v "riprap-${project_id}-claude:/root/.claude" \
    -v "riprap-${project_id}-codex:/root/.codex" \
    -e CLAUDE_CONFIG_DIR=/root/.claude \
    -w /work \
    "$image" \
    bash
