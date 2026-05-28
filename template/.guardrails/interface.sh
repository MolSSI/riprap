#!/bin/sh

image="${1:-$(cat .guardrails/podman/image_name)}"

# Without this, podman would auto-create ~/.claude.json as a directory
# on first run, breaking Claude (which expects a file at that path).
touch "${HOME}/.claude.json"

mount_pwd="$(pwd)"
mount_claude_dir="${HOME}/.claude"
mount_claude_json="${HOME}/.claude.json"

# Inside WSL, if `podman` resolves to the Windows-side binary, the volume
# mounts must use Windows paths -- podman.exe cannot read WSL paths directly.
if grep -qi microsoft /proc/version 2>/dev/null; then
    podman_path="$(command -v podman)"
    case "$podman_path" in
        *.exe|/mnt/*)
            mount_pwd="$(wslpath -w "$mount_pwd")"
            mount_claude_dir="$(wslpath -w "$mount_claude_dir")"
            mount_claude_json="$(wslpath -w "$mount_claude_json")"
            ;;
    esac
fi

podman run --rm -it \
    -v "${mount_pwd}:/work" \
    -v "${mount_claude_dir}:/root/.claude:cached" \
    -v "${mount_claude_json}:/root/.claude.json" \
    -w /work \
    "$image" \
    bash
