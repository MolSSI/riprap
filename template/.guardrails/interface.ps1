param(
    [string]$Image
)

if (-not $Image) {
    $Image = (Get-Content .guardrails/podman/image_name -Raw).Trim()
}

$claudeDir = Join-Path $HOME ".claude"
$claudeJson = Join-Path $HOME ".claude.json"

# Without this, podman would auto-create ~/.claude.json as a directory
# on first run, breaking Claude (which expects a file at that path).
if (-not (Test-Path $claudeJson)) {
    New-Item -ItemType File -Path $claudeJson | Out-Null
}

podman run --rm -it `
    -v "${PWD}:/work" `
    -v "${claudeDir}:/root/.claude:cached" `
    -v "${claudeJson}:/root/.claude.json" `
    -w /work `
    $Image `
    bash
