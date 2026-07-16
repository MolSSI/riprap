param(
    [string]$Image,
    [Parameter(Mandatory=$true)][string]$ProjectId
)

if (-not $Image) {
    $Image = (Get-Content .guardrails/podman/image_name -Raw).Trim()
}

podman run --rm -it `
    -v "${PWD}:/work" `
    -v "guardrails-${ProjectId}-claude:/root/.claude" `
    -v "guardrails-${ProjectId}-codex:/root/.codex" `
    -w /work `
    $Image `
    bash
