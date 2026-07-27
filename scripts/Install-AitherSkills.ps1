<#
.SYNOPSIS
    Install the aither-skills pack into whatever agents are on this machine.

.DESCRIPTION
    Two skill layouts exist in the wild, and installing the wrong one is why an agent
    "can't see" skills that are sitting right there on disk:

        folder : <root>\<name>\SKILL.md   - the agentskills.io standard (most agents)
        flat   : <root>\<name>.md         - Claude Code slash commands

    This repo ships flat skills\*.md; this script converts per target. Copies are
    byte-identical - only the path and filename change.

    Safe by default: never overwrites without -Force, and -DryRun writes nothing.

.PARAMETER DryRun
    Show what would be written; write nothing.

.PARAMETER Force
    Overwrite skills that already exist at the destination.

.PARAMETER List
    List detected agents and exit.

.PARAMETER Target
    Install only into these agents (e.g. openclaw,hermes). Explicitly named targets are
    installed even if the agent isn't detected - useful when provisioning ahead of time.

.PARAMETER Only
    Install only these skills (e.g. local-inference,ship-an-app-free).

.EXAMPLE
    pwsh -File scripts/Install-AitherSkills.ps1 -List

.EXAMPLE
    pwsh -File scripts/Install-AitherSkills.ps1 -Target openclaw -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$List,
    [string[]]$Target,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'

$srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills'
if (-not (Test-Path $srcDir)) {
    throw "skills/ not found next to this script - run it from a clone of the repo"
}

# `pwsh -File script.ps1 -Only a,b` hands the whole "a,b" over as ONE string element,
# unlike an in-session call where PowerShell splits it into an array. Both invocation
# styles are documented, so normalise here rather than silently matching nothing —
# that presented as "-Only selected zero skills" with no error at all.
function Split-ListArg([string[]]$Value) {
    if (-not $Value) { return @() }
    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Target = Split-ListArg $Target
$Only   = Split-ListArg $Only

$home_ = $HOME
$cwd = (Get-Location).Path

# Agents relocate their config dirs between versions. If a Path below is wrong for your
# version, check that agent's own docs - the Layout is stable even when the Path is not.
# DetectRoot is the agent's config ROOT: we do not create trees for agents that aren't
# installed, which would litter the home directory.
$targets = @(
    [pscustomobject]@{ Name='claude-code';        Layout='flat';   Path="$home_\.claude\commands";        DetectRoot="$home_\.claude" }
    [pscustomobject]@{ Name='claude-code-skills'; Layout='folder'; Path="$home_\.claude\skills";          DetectRoot="$home_\.claude" }
    [pscustomobject]@{ Name='openclaw';           Layout='folder'; Path="$home_\.openclaw\workspace\skills"; DetectRoot="$home_\.openclaw" }
    [pscustomobject]@{ Name='hermes';             Layout='folder'; Path="$home_\.hermes\skills";          DetectRoot="$home_\.hermes" }
    [pscustomobject]@{ Name='tau';                Layout='folder'; Path="$home_\.tau\skills";             DetectRoot="$home_\.tau" }
    # Cross-agent `~/.agents/skills` convention (tau reads it; designed for any agent to
    # adopt). No agent owns the dir, so its existence is the opt-in signal.
    [pscustomobject]@{ Name='agents-shared';      Layout='folder'; Path="$home_\.agents\skills";          DetectRoot="$home_\.agents" }
    [pscustomobject]@{ Name='goose';              Layout='folder'; Path="$home_\.config\goose\skills";    DetectRoot="$home_\.config\goose" }
    [pscustomobject]@{ Name='gemini';             Layout='folder'; Path="$home_\.gemini\skills";          DetectRoot="$home_\.gemini" }
    [pscustomobject]@{ Name='codex';              Layout='folder'; Path="$home_\.codex\skills";           DetectRoot="$home_\.codex" }
    [pscustomobject]@{ Name='cursor';             Layout='folder'; Path="$cwd\.cursor\skills";            DetectRoot="$cwd\.cursor" }
    [pscustomobject]@{ Name='opencode';           Layout='folder'; Path="$cwd\.opencode\skills";          DetectRoot="$cwd\.opencode" }
)

Write-Host ""
Write-Host "  aither-skills installer"
Write-Host "  source: $srcDir"
Write-Host ""

if ($List) {
    Write-Host "  detected agents:"
    $found = $false
    foreach ($t in $targets) {
        if (Test-Path $t.DetectRoot) {
            Write-Host ("    {0,-20} {1,-7} {2}" -f $t.Name, $t.Layout, $t.Path)
            $found = $true
        }
    }
    if (-not $found) {
        Write-Host "    (none - install an agent first, or pass -Target explicitly)"
    }
    Write-Host ""
    return
}

$sources = Get-ChildItem -Path $srcDir -Filter '*.md' -File
if ($Only) { $sources = $sources | Where-Object { $Only -contains $_.BaseName } }

$installedTotal = 0
$targetsHit = 0

foreach ($t in $targets) {
    if ($Target -and ($Target -notcontains $t.Name)) { continue }
    # -Target is an explicit request: honour it even when the agent isn't detected.
    if (-not $Target -and -not (Test-Path $t.DetectRoot)) { continue }

    $targetsHit++
    Write-Host ("  -> {0} ({1})" -f $t.Name, $t.Layout)
    Write-Host ("     {0}" -f $t.Path)

    $installed = 0
    $skipped = 0

    foreach ($src in $sources) {
        if ($t.Layout -eq 'folder') {
            $destDir = Join-Path $t.Path $src.BaseName
            $dest = Join-Path $destDir 'SKILL.md'
        } else {
            $destDir = $t.Path
            $dest = Join-Path $t.Path $src.Name
        }

        if ((Test-Path $dest) -and -not $Force) { $skipped++; continue }

        if ($DryRun) {
            Write-Host "       would write $dest"
        } else {
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -Path $src.FullName -Destination $dest -Force
        }
        $installed++
    }

    if ($DryRun) {
        Write-Host ("       {0} would be installed, {1} already present" -f $installed, $skipped)
    } else {
        Write-Host ("       {0} installed, {1} skipped (already present - use -Force to overwrite)" -f $installed, $skipped)
    }
    Write-Host ""
    $installedTotal += $installed
}

if ($targetsHit -eq 0) {
    Write-Host "  No agents detected."
    Write-Host ""
    Write-Host "  Install one first, or name it explicitly:"
    Write-Host "    pwsh -File scripts/Install-AitherSkills.ps1 -Target openclaw"
    Write-Host "    pwsh -File scripts/Install-AitherSkills.ps1 -List"
    Write-Host ""
    exit 1
}

if ($DryRun) {
    Write-Host "  Dry run - nothing was written. Re-run without -DryRun to install."
    Write-Host ""
} else {
    Write-Host ("  Done: {0} skill files installed across {1} target(s)." -f $installedTotal, $targetsHit)
    Write-Host ""
    Write-Host "  RESTART your agent - skills are read at startup."
    Write-Host '  Then ask it: "list the aither skills you can see"'
    Write-Host ""
}
