param(
    [string]$Image
)

if (-not $Image) {
    $Image = (Get-Content .guardrails/podman/image_name -Raw).Trim()
}

podman run --rm -it `
    -v "${PWD}:/work" `
    -w /work `
    $Image `
    bash
