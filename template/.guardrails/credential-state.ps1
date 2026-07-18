param(
    [ValidateSet("Ensure", "Reset", "InstallHooks")][string]$Action = "Ensure",
    [string]$Agent,
    [string]$Confirmation
)
$ErrorActionPreference = "Stop"
$idPath = ".guardrails/project-id"
$uuidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'

function Fail([string]$Message) { throw "Guardrails: $Message" }
function Read-ProjectId {
    if ((Test-Path $idPath) -and ((Get-Item $idPath -Force).LinkType)) { Fail "$idPath must not be a symbolic link" }
    if (-not (Test-Path $idPath -PathType Leaf)) { Fail "$idPath must be a regular file" }
    $value = Get-Content $idPath -Raw
    if ($value -cnotmatch "^($uuidPattern)\r?\n$") { Fail "$idPath must contain one canonical lowercase UUID" }
    return $Matches[1]
}
function Ensure-State {
    if (-not (Test-Path $idPath)) {
        $temporary = "$idPath.tmp.$PID"
        $value = [guid]::NewGuid().ToString("D").ToLowerInvariant()
        try {
            [IO.File]::WriteAllText($temporary, "$value`n", [Text.UTF8Encoding]::new($false))
            if (-not (Test-Path $idPath)) { [IO.File]::Move($temporary, $idPath) }
        } finally { Remove-Item $temporary -ErrorAction SilentlyContinue }
    }
    $id = Read-ProjectId
    foreach ($name in @("claude", "codex")) {
        $volume = "guardrails-$id-$name"
        podman volume inspect $volume *> $null
        if ($LASTEXITCODE -ne 0) { podman volume create $volume *> $null; if ($LASTEXITCODE -ne 0) { Fail "could not create $volume" } }
    }
    Write-Output $id
}
function Reset-State {
    if ($Agent -notin @("claude", "codex", "all")) { Fail "expected claude, codex, or all" }
    $id = Read-ProjectId
    $agents = if ($Agent -eq "all") { @("claude", "codex") } else { @($Agent) }
    $volumes = $agents | ForEach-Object { "guardrails-$id-$_" }
    Write-Host "Guardrails will remove credential state volumes:"; $volumes | ForEach-Object { Write-Host "  $_" }
    if ($Confirmation -ne "--yes") {
        $answer = Read-Host "Continue? [y/N]"
        # Comparison operators return no value for a null input. Test membership instead so
        # redirected or closed stdin is treated as denial rather than accidental consent.
        if ($answer -notin @("y", "yes")) { Fail "reset cancelled" }
    }
    foreach ($volume in $volumes) { podman volume rm $volume *> $null; if ($LASTEXITCODE -ne 0) { Fail "could not remove $volume" } }
}
function Install-Hooks {
    git rev-parse --show-toplevel *> $null; if ($LASTEXITCODE -ne 0) { Fail "run this command inside a Git repository" }
    $current = git config --local --get core.hooksPath
    if ($current -and $current -ne ".guardrails/hooks") { Fail "core.hooksPath is already '$current'; leave it unchanged and compose that hook with .guardrails/hooks/check-secrets.sh --staged" }
    git config --local core.hooksPath .guardrails/hooks
    Write-Host "Guardrails Git hooks installed."
}

switch ($Action) { "Ensure" { Ensure-State }; "Reset" { Reset-State }; "InstallHooks" { Install-Hooks } }
