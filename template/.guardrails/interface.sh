#!/bin/sh

image="${1:-$(cat .guardrails/podman/image_name)}"

# Without this, podman would auto-create ~/.claude.json as a directory
# on first run, breaking Claude (which expects a file at that path).
touch "${HOME}/.claude.json"

# Ensure the Codex credential directory exists so podman mounts the host
# copy instead of auto-creating an empty root-owned directory.
mkdir -p "${HOME}/.codex"

mount_pwd="$(pwd)"
mount_claude_dir="${HOME}/.claude"
mount_claude_json="${HOME}/.claude.json"
mount_codex_dir="${HOME}/.codex"

# Inside WSL, if `podman` resolves to the Windows-side binary, the volume
# mounts must use Windows paths -- podman.exe cannot read WSL paths directly.
if grep -qi microsoft /proc/version 2>/dev/null; then
    podman_path="$(command -v podman)"
    case "$podman_path" in
        *.exe|/mnt/*)
            mount_pwd="$(wslpath -w "$mount_pwd")"
            mount_claude_dir="$(wslpath -w "$mount_claude_dir")"
            mount_claude_json="$(wslpath -w "$mount_claude_json")"
            mount_codex_dir="$(wslpath -w "$mount_codex_dir")"
            ;;
    esac
fi

podman run --rm -it \
    -v "${mount_pwd}:/work" \
    -v "${mount_claude_dir}:/root/.claude:cached" \
    -v "${mount_claude_json}:/root/.claude.json" \
    -v "${mount_codex_dir}:/root/.codex:cached" \
    -w /work \
    "$image" \
    bash
