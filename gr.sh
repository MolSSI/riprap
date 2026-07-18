#!/bin/sh

set -eu

case "${1:-}" in
    --reset-agent-state)
        shift
        exec .guardrails/credential-state.sh reset "${1:-}" "${2:-}"
        ;;
    --install-git-hooks)
        exec .guardrails/credential-state.sh install-hooks
        ;;
esac

project_id="$(.guardrails/credential-state.sh ensure)"
IMAGE=$(cat .guardrails/podman/image_name)

# Validate the complete pin and write transient candidate state before Podman runs.
.guardrails/agent-build.sh prepare
trap '.guardrails/agent-build.sh discard' EXIT HUP INT TERM

# Tooling failures are never treated as refresh failures.
if ! podman build -t guardrails-tooling:latest .guardrails/podman; then
    .guardrails/agent-build.sh discard
    printf 'Guardrails: tooling image build failed.\n' >&2
    exit 1
fi
tooling_id=$(podman image inspect --format '{{.Id}}' guardrails-tooling:latest)

label_value() { podman image inspect --format "{{ index .Labels \"$1\" }}" guardrails-agent:latest 2>/dev/null || true; }
is_exact_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

refresh_ok=false
if podman build -f .guardrails/podman/Agent.Containerfile \
    -t guardrails-agent:candidate .guardrails/podman; then
    claude_version=$(podman run --rm guardrails-agent:candidate claude --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    codex_version=$(podman run --rm guardrails-agent:candidate codex --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    if is_exact_version "$claude_version" && is_exact_version "$codex_version" &&
       podman build -f .guardrails/podman/AgentLabels.Containerfile \
         --build-arg "CLAUDE_VERSION=$claude_version" \
         --build-arg "CODEX_VERSION=$codex_version" \
         --build-arg "TOOLING_IMAGE_ID=$tooling_id" \
         -t guardrails-agent:latest .guardrails/podman; then
        refresh_ok=true
    fi
fi

if [ "$refresh_ok" = true ]; then
    .guardrails/agent-build.sh promote "$claude_version" "$codex_version"
elif podman image exists guardrails-agent:latest &&
     [ "$(label_value io.guardrails.tooling-image-id)" = "$tooling_id" ]; then
    .guardrails/agent-build.sh discard
    printf 'Guardrails: agent refresh failed; continuing with the compatible existing agent image.\n' >&2
else
    .guardrails/agent-build.sh discard
    printf 'Guardrails: agent refresh failed and no compatible agent image exists.\n' >&2
    exit 1
fi
trap - EXIT HUP INT TERM

podman build -t "$IMAGE" .

bash .guardrails/interface.sh "$IMAGE" "$project_id"
