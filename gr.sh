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

podman build -t guardrails-base:latest .guardrails/podman
podman build -t "$IMAGE" .

bash .guardrails/interface.sh "$IMAGE" "$project_id"
