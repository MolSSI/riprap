param(
    [string]$Image,
    [Parameter(Mandatory=$true)][string]$ProjectId
)

if (-not $Image) {
    $Image = (Get-Content .riprap/podman/image_name -Raw).Trim()
}

# Claude stores its top-level configuration file (.claude.json), which records the
# authenticated account and onboarding state, outside its credential directory by
# default. Point CLAUDE_CONFIG_DIR at the mounted Claude volume so that both the
# configuration file and the credentials persist across removal of this container.
#
# The volumes below hold credentials and session state only. Both agents' programs
# live in the agent image at versions recorded in its labels and successful build key,
# and the image disables their self-updaters, so a session runs the recorded versions.
podman run --rm -it `
    -v "${PWD}:/work" `
    -v "riprap-${ProjectId}-claude:/root/.claude" `
    -v "riprap-${ProjectId}-codex:/root/.codex" `
    -e CLAUDE_CONFIG_DIR=/root/.claude `
    -w /work `
    $Image `
    bash
