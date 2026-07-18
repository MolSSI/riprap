param(
    [string]$Image,
    [Parameter(Mandatory=$true)][string]$ProjectId
)

if (-not $Image) {
    $Image = (Get-Content .guardrails/podman/image_name -Raw).Trim()
}

# Claude stores its top-level configuration file (.claude.json), which records the
# authenticated account and onboarding state, outside its credential directory by
# default. Point CLAUDE_CONFIG_DIR at the mounted Claude volume so that both the
# configuration file and the credentials persist across removal of this container.
podman run --rm -it `
    -v "${PWD}:/work" `
    -v "guardrails-${ProjectId}-claude:/root/.claude" `
    -v "guardrails-${ProjectId}-codex:/root/.codex" `
    -e CLAUDE_CONFIG_DIR=/root/.claude `
    -w /work `
    $Image `
    bash
