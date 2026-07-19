#!/bin/sh

set -eu

case "${1:-}" in
    --reset-agent-state)
        shift
        exec .riprap/managed/launch/credential-state.sh reset "${1:-}" "${2:-}"
        ;;
    --install-git-hooks)
        exec .riprap/managed/launch/credential-state.sh install-hooks
        ;;
esac

project_id="$(.riprap/managed/launch/credential-state.sh ensure)"
IMAGE=$(cat .riprap/managed/podman/image_name)

# Validate the complete pin and write transient candidate state before Podman runs.
.riprap/managed/launch/agent-build.sh prepare
trap '.riprap/managed/launch/agent-build.sh discard' EXIT HUP INT TERM
candidate_file=.riprap/state/podman/agent-build.candidate.env
candidate_claude_version=$(sed -n 's/^CLAUDE_VERSION=//p' "$candidate_file" | tr -d '\r' | head -n 1)
candidate_codex_version=$(sed -n 's/^CODEX_VERSION=//p' "$candidate_file" | tr -d '\r' | head -n 1)

# Tooling failures are never treated as refresh failures.
if ! podman build -t riprap-tooling:latest .riprap/managed/podman; then
    .riprap/managed/launch/agent-build.sh discard
    printf 'Riprap: tooling image build failed.\n' >&2
    exit 1
fi
tooling_id=$(podman image inspect --format '{{.Id}}' riprap-tooling:latest)

label_value() { podman image inspect --format "{{ index .Labels \"$1\" }}" riprap-agent:latest 2>/dev/null || true; }
is_exact_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

refresh_ok=false
if podman build -f .riprap/managed/podman/Agent.Containerfile \
    --build-arg "CLAUDE_VERSION=$candidate_claude_version" \
    --build-arg "CODEX_VERSION=$candidate_codex_version" \
    -t riprap-agent:candidate .riprap/managed/podman; then
    claude_version=$(podman run --rm riprap-agent:candidate claude --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    codex_version=$(podman run --rm riprap-agent:candidate codex --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    if is_exact_version "$claude_version" && is_exact_version "$codex_version" &&
       podman build -f .riprap/managed/podman/AgentLabels.Containerfile \
         --build-arg "CLAUDE_VERSION=$claude_version" \
         --build-arg "CODEX_VERSION=$codex_version" \
         --build-arg "TOOLING_IMAGE_ID=$tooling_id" \
         -t riprap-agent:latest .riprap/managed/podman; then
        refresh_ok=true
    fi
fi

if [ "$refresh_ok" = true ]; then
    .riprap/managed/launch/agent-build.sh promote "$claude_version" "$codex_version"
elif podman image exists riprap-agent:latest &&
     [ "$(label_value io.riprap.tooling-image-id)" = "$tooling_id" ]; then
    .riprap/managed/launch/agent-build.sh discard
    printf 'Riprap: agent refresh failed; continuing with the compatible existing agent image.\n' >&2
else
    .riprap/managed/launch/agent-build.sh discard
    printf 'Riprap: agent refresh failed and no compatible agent image exists.\n' >&2
    exit 1
fi
trap - EXIT HUP INT TERM

podman build -t "$IMAGE" .

bash .riprap/managed/launch/interface.sh "$IMAGE" "$project_id"
