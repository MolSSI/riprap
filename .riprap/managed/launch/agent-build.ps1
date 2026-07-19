$ErrorActionPreference = "Stop"

$keyFile = ".riprap/state/podman/agent-build.env"
$candidateFile = ".riprap/state/podman/agent-build.candidate.env"
$pinFile = ".riprap/user/agent-pin.env"
$versionPattern = '^[0-9]+\.[0-9]+\.[0-9]+$'

function Fail([string]$Message) {
    # An uncaught exception is reformatted and line-wrapped by Windows PowerShell, making
    # diagnostics host-width dependent. Emit the launcher contract directly instead.
    [Console]::Error.WriteLine("Riprap: $Message")
    exit 1
}

function Get-IsoWeekStamp([datetime]$Date = (Get-Date).ToUniversalTime()) {
    $utc = $Date.ToUniversalTime()
    $dayNumber = [int]$utc.DayOfWeek
    if ($dayNumber -eq 0) { $dayNumber = 7 }
    $thursday = $utc.Date.AddDays(4 - $dayNumber)
    $calendar = [Globalization.CultureInfo]::InvariantCulture.Calendar
    $week = $calendar.GetWeekOfYear(
        $thursday, [Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
    return "{0}-W{1:D2}" -f $thursday.Year, $week
}

function Prepare-AgentBuild {
    New-Item -ItemType Directory -Force -Path ".riprap/state/podman" | Out-Null
    $claudeVersion = "latest"
    $codexVersion = "latest"
    $refresh = Get-IsoWeekStamp

    if (Test-Path -LiteralPath $pinFile) {
        if (-not (Test-Path -LiteralPath $pinFile -PathType Leaf)) { Fail "$pinFile must be a regular file" }
        $seen = @{}
        $lines = @(Get-Content -LiteralPath $pinFile)
        if ($lines.Count -eq 0) { Fail "$pinFile is empty" }
        foreach ($line in $lines) {
            if (-not $line -or $line -notmatch '^([^=]+)=(.*)$') { Fail "$pinFile contains a malformed line: '$line'" }
            $name = $Matches[1]
            $value = $Matches[2]
            # Checks run in a fixed precedence so that every launcher reports the same defect
            # for the same file: structure, then name, then repetition, then value.
            if ($name -notin @("CLAUDE_VERSION", "CODEX_VERSION")) { Fail "$pinFile contains unknown assignment '$name'" }
            if ($seen.ContainsKey($name)) { Fail "$pinFile contains duplicate $name assignments" }
            if (-not $value) { Fail "${pinFile}: $name has an empty value" }
            if ($value -notmatch $versionPattern) { Fail "${pinFile}: $name must be an exact release version such as 1.2.3, but is '$value'" }
            $seen[$name] = $value
        }
        if ($seen.CLAUDE_VERSION) { $claudeVersion = $seen.CLAUDE_VERSION }
        if ($seen.CODEX_VERSION) { $codexVersion = $seen.CODEX_VERSION }
        if ($seen.Count -eq 2) { $refresh = "pinned" }
    }

    $temporary = "$candidateFile.tmp.$PID"
    try {
        $contents = "CLAUDE_VERSION=$claudeVersion`nCODEX_VERSION=$codexVersion`nREFRESH=$refresh`n"
        [IO.File]::WriteAllText($temporary, $contents, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $candidateFile -Force
    } finally { Remove-Item $temporary -ErrorAction SilentlyContinue }
}

switch ($args[0]) {
    { $_ -in @($null, "", "prepare") } { Prepare-AgentBuild; break }
    "promote" {
        if (-not (Test-Path -LiteralPath $candidateFile -PathType Leaf)) { Fail "no agent build candidate exists" }
        if (-not $args[1] -or -not $args[2]) { Fail "promote requires exact Claude and Codex versions" }
        $contents = (Get-Content -LiteralPath $candidateFile | Where-Object { $_ -notmatch '^INSTALLED_' }) -join "`n"
        $contents += "`nINSTALLED_CLAUDE_VERSION=$($args[1])`nINSTALLED_CODEX_VERSION=$($args[2])`n"
        [IO.File]::WriteAllText($keyFile, $contents, [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $candidateFile -Force
        break
    }
    "discard" { Remove-Item -LiteralPath $candidateFile -ErrorAction SilentlyContinue; break }
    "week" {
        if (-not $args[1]) { Fail "week requires a date" }
        # Parsed as UTC so the stamp does not shift with the host's time zone.
        Get-IsoWeekStamp ([datetime]::Parse($args[1], [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
        break
    }
    default { Fail "unknown agent build action '$($args[0])'" }
}
