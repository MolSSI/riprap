#Requires -Version 5.1
# Windows launch-path validation.
#
# Launch orchestration is observable from the commands a launcher issues and the state it
# writes, so these tests substitute a mock container runtime for Podman and never build an
# image. That keeps the suite runnable on a stock Windows runner with no container runtime,
# virtualization, or Linux subsystem. Image content is validated separately, on a host that
# has a real rootless Podman.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$OriginalPath = $env:PATH
$Failures = 0

function Fail([string]$Message) { throw "FAIL: $Message" }

function Render-Project([string]$Destination) {
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 represents redirected native stderr as error records.
        # Copier writes its harmless template-version notice there, so rely on its exit
        # status rather than promoting that notice to a terminating PowerShell error.
        $ErrorActionPreference = "Continue"
        & copier copy --trust --defaults `
            --data project_name='Windows Test' --data project_slug='windows-test' `
            --data project_description='test' --data language=rust `
            --data include_rust_skeleton=false --data author_name=Test `
            --data author_email=test@example.com --data open_source_license='Not Open Source' `
            $Root $Destination 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) { Fail "copier could not render a project" }
}

# The mock records every invocation and answers only the subcommands a launcher issues.
# It is written with gotos rather than parenthesized blocks because cmd.exe parses a block
# before expanding it, and agent version strings contain parentheses.
function New-MockPodman([string]$BinDirectory) {
    $mock = @'
@echo off
setlocal EnableDelayedExpansion
>>"%PODMAN_LOG%" echo %*
if /i "%~1"=="volume" goto volume
if /i "%~1"=="image" goto image
if /i "%~1"=="build" goto build
if /i "%~1"=="run" goto run
exit /b 0

:volume
if /i "%~2"=="inspect" goto volume_inspect
if /i "%~2"=="create" goto volume_create
if /i "%~2"=="rm" goto volume_rm
exit /b 0
:volume_inspect
if exist "%MOCK_VOLUMES%\%~3\" exit /b 0
exit /b 1
:volume_create
mkdir "%MOCK_VOLUMES%\%~3" 2>nul
echo %~3
exit /b 0
:volume_rm
rmdir /s /q "%MOCK_VOLUMES%\%~3" 2>nul
exit /b 0

:image
if /i "%~2"=="exists" exit /b %MOCK_IMAGE_EXISTS%
if /i "%~2"=="inspect" goto image_inspect
exit /b 0
:image_inspect
echo tooling-id
exit /b 0

:build
if "%MOCK_FAIL_BUILD%"=="" exit /b 0
echo %*| findstr /c:"%MOCK_FAIL_BUILD%" >nul
if not errorlevel 1 exit /b 1
exit /b 0

:run
echo %*| findstr /c:"claude --version" >nul
if not errorlevel 1 goto emit_claude
echo %*| findstr /c:"codex --version" >nul
if not errorlevel 1 goto emit_codex
exit /b 0
:emit_claude
echo !MOCK_CLAUDE_VERSION!
exit /b 0
:emit_codex
echo !MOCK_CODEX_VERSION!
exit /b 0
'@
    # Written with CRLF: cmd.exe mis-parses goto targets in a batch file that uses LF.
    $mock = $mock -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path $BinDirectory "podman.cmd"), $mock, [Text.Encoding]::ASCII)
}

function New-TestProject {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("gr-" + [Guid]::NewGuid().ToString("N").Substring(0, 12))
    $project = Join-Path $temp "project"
    $bin = Join-Path $temp "bin"
    $volumes = Join-Path $temp "volumes"
    New-Item -ItemType Directory -Force -Path $bin, $volumes | Out-Null
    Render-Project $project
    New-MockPodman $bin

    $env:PATH = "$bin;$OriginalPath"
    $env:PODMAN_LOG = Join-Path $temp "podman.log"
    $env:MOCK_VOLUMES = $volumes
    $env:MOCK_IMAGE_EXISTS = "0"
    $env:MOCK_FAIL_BUILD = ""
    $env:MOCK_CLAUDE_VERSION = "2.1.205 (Claude Code)"
    $env:MOCK_CODEX_VERSION = "codex-cli 0.144.6"
    New-Item -ItemType File -Force -Path $env:PODMAN_LOG | Out-Null

    return [pscustomobject]@{ Temp = $temp; Project = $project }
}

# gr.bat ends with "pause", so stdin is redirected to keep the launcher non-interactive.
function Invoke-Launcher([string]$Project) {
    Push-Location $Project
    try {
        $output = cmd.exe /c "gr.bat <NUL 2>&1"
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    # Calling ToString() on native error records preserves the child's diagnostic. Sending
    # them through Out-String invokes PowerShell's error formatter, which inserts context and
    # may wrap or truncate the message according to the host width.
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Output = $text; ExitCode = $code }
}

function Invoke-AgentBuild([string]$Project, [string[]]$Arguments) {
    Push-Location $Project
    $savedPreference = $ErrorActionPreference
    try {
        # Several validation cases intentionally capture native stderr from a failing
        # child process. Its exit code remains the source of truth.
        $ErrorActionPreference = "Continue"
        $output = & powershell -NoProfile -ExecutionPolicy Bypass `
            -File ".guardrails/agent-build.ps1" @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
        Pop-Location
    }
    return [pscustomobject]@{ Output = ($output | Out-String); ExitCode = $code }
}

function Get-PodmanLog { Get-Content -LiteralPath $env:PODMAN_LOG -Raw -ErrorAction SilentlyContinue }

function Get-BuildKeyValue([string]$Project, [string]$Name) {
    $path = Join-Path $Project ".guardrails/podman/agent-build.env"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match "^$Name=(.*)$") { return $Matches[1] }
    }
    return $null
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok   $Name"
    } catch {
        $script:Failures++
        Write-Host "  FAIL $Name"
        Write-Host "       $($_.Exception.Message)"
    } finally {
        $env:PATH = $OriginalPath
    }
}

Write-Host "Windows launcher validation"

# rq-17a864bb
Test-Case "the Windows launcher validates the pin before building" {
    $t = New-TestProject
    Set-Content -LiteralPath (Join-Path $t.Project ".guardrails/agent-pin.env") -Value "CLAUDE_VERSION=latest"
    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -eq 0) { Fail "a non-exact pin was accepted" }
    if ($result.Output -notmatch "CLAUDE_VERSION") { Fail "the offending assignment is not identified" }
    if ((Get-PodmanLog) -match "(?m)^build ") { Fail "an image was built despite a malformed pin" }
}

# rq-13d744b1
Test-Case "the Windows launcher stops on a tooling build failure" {
    $t = New-TestProject
    $env:MOCK_FAIL_BUILD = "guardrails-tooling"
    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -eq 0) { Fail "a tooling build failure did not stop the launch" }
    if ($result.Output -notmatch "tooling image build failed") { Fail "the tooling failure was not identified" }
    if ($result.Output -match "agent refresh failed") { Fail "a tooling failure was described as a refresh failure" }
    if (Test-Path -LiteralPath (Join-Path $t.Project ".guardrails/podman/agent-build.candidate.env")) {
        Fail "the tooling failure left candidate state behind"
    }
}

# rq-b68a63b5
Test-Case "the Windows launcher falls back to a compatible agent image" {
    $t = New-TestProject
    $key = Join-Path $t.Project ".guardrails/podman/agent-build.env"
    Set-Content -LiteralPath $key -Value @(
        "CLAUDE_VERSION=latest", "CODEX_VERSION=latest", "REFRESH=1970-W01",
        "INSTALLED_CLAUDE_VERSION=1.0.0", "INSTALLED_CODEX_VERSION=1.0.0")
    $before = Get-FileHash -LiteralPath $key
    $env:MOCK_FAIL_BUILD = "Agent.Containerfile"
    $env:MOCK_IMAGE_EXISTS = "0"

    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -ne 0) { Fail "the launch aborted despite a compatible agent image" }
    if ($result.Output -notmatch "agent refresh failed") { Fail "the failed refresh was not reported" }
    if ((Get-PodmanLog) -notmatch "run --rm") { Fail "no development container was started" }
    if ((Get-FileHash -LiteralPath $key).Hash -ne $before.Hash) { Fail "a failed refresh changed the successful build key" }
    if (Test-Path -LiteralPath (Join-Path $t.Project ".guardrails/podman/agent-build.candidate.env")) {
        Fail "a failed refresh left candidate state behind"
    }
}

# rq-f69aa150
Test-Case "the Windows launcher stops when no compatible agent image exists" {
    $t = New-TestProject
    $env:MOCK_FAIL_BUILD = "Agent.Containerfile"
    $env:MOCK_IMAGE_EXISTS = "1"
    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -eq 0) { Fail "the launch continued with no compatible agent image" }
    if ($result.Output -notmatch "no compatible agent image exists") { Fail "the failure was not explained" }
    if ((Get-PodmanLog) -match "run --rm -it") { Fail "a development container was started anyway" }
}

# A version the launcher cannot parse must not be labeled, and must not be filled in from
# an ambient variable that happens to share a name with a build-key assignment.
# rq-41eeda01 rq-fedf48c5
Test-Case "the Windows launcher refuses an agent version it cannot parse" {
    $t = New-TestProject
    $env:MOCK_CLAUDE_VERSION = "not-a-version"
    $env:MOCK_IMAGE_EXISTS = "1"
    $env:CLAUDE_VERSION = "9.9.9"
    try {
        $result = Invoke-Launcher $t.Project
        if ($result.ExitCode -eq 0) { Fail "an unparseable agent version was accepted" }
        if ((Get-PodmanLog) -match "AgentLabels") { Fail "the agent image was labeled with an unparseable version" }
        if ((Get-PodmanLog) -match "9\.9\.9") { Fail "an ambient CLAUDE_VERSION reached the image labels" }
        if (Test-Path -LiteralPath (Join-Path $t.Project ".guardrails/podman/agent-build.env")) {
            Fail "an unparseable version was promoted to the successful build key"
        }
    } finally { Remove-Item Env:CLAUDE_VERSION -ErrorAction SilentlyContinue }
}

# rq-ce1eb03c
Test-Case "the Windows launcher records the numeric core of suffixed agent versions" {
    $t = New-TestProject
    $env:MOCK_CLAUDE_VERSION = "2.1.205-beta (Claude Code)"
    $env:MOCK_CODEX_VERSION = "codex-cli 0.144.6-preview"
    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -ne 0) { Fail "suffixed agent versions caused a refresh failure" }
    if ((Get-BuildKeyValue $t.Project "INSTALLED_CLAUDE_VERSION") -ne "2.1.205") {
        Fail "the Claude numeric release core was not recorded"
    }
    if ((Get-BuildKeyValue $t.Project "INSTALLED_CODEX_VERSION") -ne "0.144.6") {
        Fail "the Codex numeric release core was not recorded"
    }
}

# Both implementations derive the stamp for the same date and the results are compared.
# Inspecting either implementation's source would prove nothing about the other.
# rq-26d8643a
Test-Case "Windows and shell launchers agree at ISO year boundaries" {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Fail "bash is required to compare the two implementations" }
    $t = New-TestProject

    # Each date's ISO week-year differs from its calendar year, or sits on the boundary.
    $dates = @{
        "2019-12-30" = "2020-W01"; "2020-12-31" = "2020-W53"; "2021-01-01" = "2020-W53"
        "2021-01-04" = "2021-W01"; "2022-01-01" = "2021-W52"; "2024-12-30" = "2025-W01"
        "2026-12-31" = "2026-W53"; "2017-01-01" = "2016-W52"; "2023-06-15" = "2023-W24"
    }
    Push-Location $t.Project
    try {
        foreach ($date in $dates.Keys) {
            $expected = $dates[$date]
            $shell = (& $bash.Source ".guardrails/agent-build.sh" week $date 2>&1 | Out-String).Trim()
            $windows = (Invoke-AgentBuild $t.Project @("week", $date)).Output.Trim()
            if ($shell -ne $expected) { Fail "the shell stamp for $date is '$shell', not '$expected'" }
            if ($windows -ne $expected) { Fail "the Windows stamp for $date is '$windows', not '$expected'" }
        }
    } finally { Pop-Location }
}

# The same pin content must produce the same account of what is wrong on every platform.
# rq-13f28b2e rq-c2cdf6d8
Test-Case "both launchers report the same defect for the same invalid pin" {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { Fail "bash is required to compare the two implementations" }
    $t = New-TestProject
    $pin = Join-Path $t.Project ".guardrails/agent-pin.env"

    $pins = @(
        @("",                                       "an empty pin"),
        @("CLAUDE_VERSION=",                        "an empty value"),
        @("CLAUDE_VERSION=latest",                  "a non-exact version"),
        @("CLAUDE_VERSOIN=1.2.3",                   "an unknown name"),
        @("CLAUDE_VERSOIN=not-a-version",           "an unknown name paired with a bad value"),
        @("CLAUDE_VERSION=1.2.3`nCLAUDE_VERSION=1.2.4", "a duplicate name"),
        @("not-an-assignment",                      "a malformed line")
    )

    foreach ($case in $pins) {
        [IO.File]::WriteAllText($pin, $case[0], [Text.UTF8Encoding]::new($false))
        Push-Location $t.Project
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $shellOutput = & $bash.Source ".guardrails/agent-build.sh" prepare 2>&1
            $shell = ($shellOutput | ForEach-Object { $_.ToString() }) -join "`n"
        } finally {
            $ErrorActionPreference = $savedPreference
            Pop-Location
        }
        $windows = (Invoke-AgentBuild $t.Project @("prepare")).Output

        $shellMessage = ([regex]::Match($shell, 'Guardrails: [^\r\n]+')).Value.Trim()
        $windowsMessage = ([regex]::Match($windows, 'Guardrails: [^\r\n]+')).Value.Trim()
        if (-not $shellMessage) { Fail "the shell launcher accepted $($case[1])" }
        if (-not $windowsMessage) { Fail "the Windows launcher accepted $($case[1])" }
        if ($shellMessage -ne $windowsMessage) {
            Fail "$($case[1]) is reported as '$shellMessage' by the shell and '$windowsMessage' by Windows"
        }
    }
}

# Attributes describe the rules that should apply; these assertions read the bytes an
# interpreter will actually receive, which only a Windows checkout can establish.
# rq-003ece26
Test-Case "a Windows checkout carries the line endings its interpreters need" {
    $tracked = & git -C $Root ls-files -- template
    if ($LASTEXITCODE -ne 0) { Fail "could not enumerate version-controlled scripts" }
    $lfPaths = @($tracked | Where-Object { $_ -match '\.(sh|ps1)$' }) + @("template/.guardrails/hooks/pre-commit")
    $crlfPaths = @($tracked | Where-Object { $_ -match '\.(bat|cmd)$' })

    foreach ($relative in $lfPaths | Sort-Object -Unique) {
        $full = Join-Path $Root $relative
        $bytes = [IO.File]::ReadAllBytes($full)
        if ($bytes -contains 13) { Fail "$relative contains a CR byte instead of using only LF line endings" }
    }
    foreach ($relative in $crlfPaths) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $relative))
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) {
                Fail "$relative contains an LF not preceded by CR"
            }
            if ($bytes[$i] -eq 13 -and ($i + 1 -ge $bytes.Length -or $bytes[$i + 1] -ne 10)) {
                Fail "$relative contains a CR not followed by LF"
            }
        }
    }
}

# rq-6b0d184f
Test-Case "the Windows credential helper creates the same project identity" {
    $t = New-TestProject
    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -ne 0) { Fail "the launch failed: $($result.Output)" }
    $id = (Get-Content -LiteralPath (Join-Path $t.Project ".guardrails/project-id") -Raw).Trim()
    if ($id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
        Fail "the project identity '$id' is not a canonical lowercase UUID"
    }
    foreach ($agent in @("claude", "codex")) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:MOCK_VOLUMES "guardrails-$id-$agent"))) {
            Fail "the $agent volume was not created with the shared naming convention"
        }
    }
}

# rq-5e481eb3
Test-Case "the Windows credential helper reuses an existing project identity" {
    $t = New-TestProject
    Invoke-Launcher $t.Project | Out-Null
    $idPath = Join-Path $t.Project ".guardrails/project-id"
    $first = (Get-Content -LiteralPath $idPath -Raw).Trim()
    foreach ($agent in @("claude", "codex")) {
        New-Item -ItemType File -Force -Path (Join-Path $env:MOCK_VOLUMES "guardrails-$first-$agent/marker") | Out-Null
    }
    Clear-Content -LiteralPath $env:PODMAN_LOG
    Invoke-Launcher $t.Project | Out-Null
    $second = (Get-Content -LiteralPath $idPath -Raw).Trim()
    if ($first -ne $second) { Fail "the project identity changed between launches" }
    foreach ($agent in @("claude", "codex")) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:MOCK_VOLUMES "guardrails-$first-$agent/marker"))) {
            Fail "the $agent volume was recreated rather than reused"
        }
    }
    if ((Get-PodmanLog) -match "(?m)^volume create ") { Fail "an existing credential volume was created again" }
}

# rq-8c955028
Test-Case "the Windows reset requires explicit confirmation" {
    $t = New-TestProject
    Invoke-Launcher $t.Project | Out-Null
    $id = (Get-Content -LiteralPath (Join-Path $t.Project ".guardrails/project-id") -Raw).Trim()
    Push-Location $t.Project
    try { cmd.exe /c "gr.bat --reset-agent-state all <NUL 2>&1" | Out-Null } finally { Pop-Location }
    foreach ($agent in @("claude", "codex")) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:MOCK_VOLUMES "guardrails-$id-$agent"))) {
            Fail "the $agent volume was removed without explicit confirmation"
        }
    }
}

# rq-77328390
Test-Case "a malformed project identity blocks the Windows launcher" {
    $t = New-TestProject
    Set-Content -LiteralPath (Join-Path $t.Project ".guardrails/project-id") -Value "not-a-uuid"
    $result = Invoke-Launcher $t.Project
    if ($result.ExitCode -eq 0) { Fail "a malformed project identity did not stop the launch" }
    if ((Get-PodmanLog) -match "run --rm -it") { Fail "a development container started with a malformed identity" }
}

if ($Failures -gt 0) {
    Write-Host "FAIL: $Failures Windows launcher test(s) failed"
    exit 1
}
Write-Host "PASS: Windows launch path"
