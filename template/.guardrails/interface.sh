#!/bin/sh

image="${1:-$(cat .guardrails/podman/image_name)}"

mount_path="$(pwd)"

# Inside WSL, if `podman` resolves to the Windows-side binary, the volume
# mount must be a Windows path -- podman.exe cannot read WSL paths directly.
if grep -qi microsoft /proc/version 2>/dev/null; then
    podman_path="$(command -v podman)"
    case "$podman_path" in
        *.exe|/mnt/*)
            mount_path="$(wslpath -w "$(pwd)")"
            ;;
    esac
fi

podman run --rm -it \
    -v "${mount_path}:/work" \
    -w /work \
    "$image" \
    bash
