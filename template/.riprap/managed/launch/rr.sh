#!/bin/sh

set -eu

export_sif=false
case "${1:-}" in
    --reset-agent-state)
        shift
        exec .riprap/managed/launch/credential-state.sh reset "${1:-}" "${2:-}"
        ;;
    --install-git-hooks)
        exec .riprap/managed/launch/credential-state.sh install-hooks
        ;;
    --run-sif)
        # Execution host: run a previously exported image. This host builds nothing, so it never
        # touches the build runtime and only needs its workspace identity.
        project_id="$(.riprap/managed/launch/credential-state.sh project-id)"
        exec .riprap/managed/launch/apptainer-interface.sh "$project_id"
        ;;
    --export-sif)
        # Build the project image by the ordinary path below, then export it instead of launching.
        export_sif=true
        ;;
esac

project_id="$(.riprap/managed/launch/credential-state.sh ensure)"
tooling_image="localhost/riprap-$project_id-tooling:latest"
agent_candidate_image="localhost/riprap-$project_id-agent:candidate"
agent_image="localhost/riprap-$project_id-agent:latest"
project_image="localhost/riprap-$project_id-project:latest"

# Validate the complete pin and write transient candidate state before Podman runs.
.riprap/managed/launch/agent-build.sh prepare
trap '.riprap/managed/launch/agent-build.sh discard' EXIT HUP INT TERM
candidate_file=.riprap/state/container/agent-build.candidate.env
candidate_claude_version=$(sed -n 's/^CLAUDE_VERSION=//p' "$candidate_file" | tr -d '\r' | head -n 1)
candidate_codex_version=$(sed -n 's/^CODEX_VERSION=//p' "$candidate_file" | tr -d '\r' | head -n 1)
candidate_opencode_version=$(sed -n 's/^OPENCODE_VERSION=//p' "$candidate_file" | tr -d '\r' | head -n 1)

# Tooling failures are never treated as refresh failures.
if ! podman build -t "$tooling_image" .riprap/managed/container; then
    .riprap/managed/launch/agent-build.sh discard
    printf 'Riprap: tooling image build failed.\n' >&2
    exit 1
fi
tooling_id=$(podman image inspect --format '{{.Id}}' "$tooling_image")

label_value() { podman image inspect --format "{{ index .Labels \"$1\" }}" "$agent_image" 2>/dev/null || true; }
is_exact_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

refresh_ok=false
if podman build -f .riprap/managed/container/Agent.Containerfile \
    --build-arg "CLAUDE_VERSION=$candidate_claude_version" \
    --build-arg "CODEX_VERSION=$candidate_codex_version" \
    --build-arg "OPENCODE_VERSION=$candidate_opencode_version" \
    --build-arg "RIPRAP_TOOLING_IMAGE=$tooling_image" \
    -t "$agent_candidate_image" .riprap/managed/container; then
    claude_version=$(podman run --rm "$agent_candidate_image" claude --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    codex_version=$(podman run --rm "$agent_candidate_image" codex --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    opencode_version=$(podman run --rm "$agent_candidate_image" opencode --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    if is_exact_version "$claude_version" && is_exact_version "$codex_version" &&
       is_exact_version "$opencode_version" &&
       podman build -f .riprap/managed/container/AgentLabels.Containerfile \
         --build-arg "CLAUDE_VERSION=$claude_version" \
         --build-arg "CODEX_VERSION=$codex_version" \
         --build-arg "OPENCODE_VERSION=$opencode_version" \
         --build-arg "TOOLING_IMAGE_ID=$tooling_id" \
         --build-arg "RIPRAP_PROJECT_ID=$project_id" \
         --build-arg "RIPRAP_AGENT_CANDIDATE_IMAGE=$agent_candidate_image" \
         -t "$agent_image" .riprap/managed/container; then
        refresh_ok=true
    fi
fi

if [ "$refresh_ok" = true ]; then
    .riprap/managed/launch/agent-build.sh promote "$claude_version" "$codex_version" "$opencode_version"
elif podman image exists "$agent_image" &&
     [ "$(label_value io.riprap.tooling-image-id)" = "$tooling_id" ]; then
    .riprap/managed/launch/agent-build.sh discard
    printf 'Riprap: agent refresh failed; continuing with the compatible existing agent image.\n' >&2
else
    .riprap/managed/launch/agent-build.sh discard
    printf 'Riprap: agent refresh failed and no compatible agent image exists.\n' >&2
    exit 1
fi
trap - EXIT HUP INT TERM

.riprap/managed/launch/project-container.sh Containerfile .riprap/state/container/Project.Containerfile
podman build -f .riprap/state/container/Project.Containerfile \
    --build-arg "RIPRAP_AGENT_IMAGE=$agent_image" -t "$project_image" .

if [ "$export_sif" = true ]; then
    exec .riprap/managed/launch/export-sif.sh "$project_id" "$project_image"
fi

bash .riprap/managed/launch/interface.sh "$project_image" "$project_id"
