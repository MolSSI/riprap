param(
    [string]$Image
)

if (-not $Image) {
    $Image = (Get-Content .guardrails/podman/image_name -Raw).Trim()
}

$claudeDir = Join-Path $HOME ".claude"
$claudeJson = Join-Path $HOME ".claude.json"
$codexDir = Join-Path $HOME ".codex"

# Without this, podman would auto-create ~/.claude.json as a directory
# on first run, breaking Claude (which expects a file at that path).
if (-not (Test-Path $claudeJson)) {
    New-Item -ItemType File -Path $claudeJson | Out-Null
}

# Ensure the Codex credential directory exists so podman mounts the host
# copy instead of auto-creating an empty root-owned directory.
if (-not (Test-Path $codexDir)) {
    New-Item -ItemType Directory -Path $codexDir | Out-Null
}

podman run --rm -it `
    -v "${PWD}:/work" `
    -v "${claudeDir}:/root/.claude:cached" `
    -v "${claudeJson}:/root/.claude.json" `
    -v "${codexDir}:/root/.codex:cached" `
    -w /work `
    $Image `
    bash
