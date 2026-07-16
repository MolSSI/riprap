#!/bin/sh

image="${1:-$(cat .guardrails/podman/image_name)}"
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

podman run --rm -it \
    -v "${mount_pwd}:/work" \
    -v "guardrails-${project_id}-claude:/root/.claude" \
    -v "guardrails-${project_id}-codex:/root/.codex" \
    -w /work \
    "$image" \
    bash
