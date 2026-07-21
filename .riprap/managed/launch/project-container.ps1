#Requires -Version 5.1
param(
    [string]$Source = "Containerfile",
    [string]$Output = ".riprap\state\container\Project.Containerfile"
)

$ErrorActionPreference = "Stop"
$parent = Split-Path -Parent $Output
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

$content = [IO.File]::ReadAllText($Source)
$legacy = '(?m)^FROM localhost/riprap-agent:latest\r?$'
$replacement = "ARG RIPRAP_AGENT_IMAGE`r`nFROM `${RIPRAP_AGENT_IMAGE}"
$content = [Text.RegularExpressions.Regex]::Replace($content, $legacy, $replacement)
[IO.File]::WriteAllText($Output, $content, [Text.UTF8Encoding]::new($false))

