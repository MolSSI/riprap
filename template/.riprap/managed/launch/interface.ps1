param(
    [string]$Image,
    [Parameter(Mandatory=$true)][string]$ProjectId
)

if (-not $Image) {
    $Image = (Get-Content .riprap/managed/podman/image_name -Raw).Trim()
}

$runOptionsFile = ".riprap/user/podman/run-options"

function Fail([string]$Message) {
    # An uncaught exception is reformatted and line-wrapped by Windows PowerShell, making
    # diagnostics host-width dependent. Emit the launcher contract directly instead.
    [Console]::Error.WriteLine("Riprap: $Message")
    exit 1
}

# One argument per line keeps the file free of shell quoting rules, so an option reaches
# the runtime exactly as written.
#
# A line is accepted only as a single whitespace-free argument beginning with "-". Checks
# run in a fixed order -- whitespace, then leading "-" -- so a line with both defects is
# reported identically by every launcher.
$runOptions = @()
if (Test-Path -LiteralPath $runOptionsFile) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $runOptionsFile) {
        $lineNumber++
        $option = $line.Trim()
        if ($option -eq "" -or $option.StartsWith("#")) { continue }
        if ($option -match '\s') {
            Fail "${runOptionsFile} line ${lineNumber}: an option must be a single argument with no spaces: $option"
        }
        if (-not $option.StartsWith("-")) {
            Fail "${runOptionsFile} line ${lineNumber}: an option must begin with '-': $option"
        }
        $runOptions += $option
    }
}

# Claude stores its top-level configuration file (.claude.json), which records the
# authenticated account and onboarding state, outside its credential directory by
# default. Point CLAUDE_CONFIG_DIR at the mounted Claude volume so that both the
# configuration file and the credentials persist across removal of this container.
#
# The volumes below hold credentials and session state only. Both agents' programs
# live in the agent image at versions recorded in its labels and successful build key,
# and the image disables their self-updaters, so a session runs the recorded versions.
#
# The project's options follow, so a runtime that resolves a repeated option in favor of
# its last occurrence resolves it in the project's favor.
podman run --rm -it `
    -v "${PWD}:/work" `
    -v "riprap-${ProjectId}-claude:/root/.claude" `
    -v "riprap-${ProjectId}-codex:/root/.codex" `
    -e CLAUDE_CONFIG_DIR=/root/.claude `
    -w /work `
    @runOptions `
    $Image `
    bash
