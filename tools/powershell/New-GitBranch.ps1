#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a new Git branch from the current or specified base branch.

.DESCRIPTION
    Creates and switches to a new branch following conventional branch naming
    conventions (feature/*, fix/*, chore/*, etc.). Auto-prefixes if not provided.

.PARAMETER Name
    Branch name. If it doesn't include a prefix (feature/, fix/, chore/,
    hotfix/, release/, experiment/), 'feature/' will be prepended automatically.

.PARAMETER Base
    Base branch to create from. Defaults to 'develop'.

.PARAMETER NoSwitch
    Create the branch but don't switch to it.

.PARAMETER Prefixes
    Custom list of allowed branch prefixes (default: feature, fix, chore, hotfix, release, experiment).

.EXAMPLE
    New-GitBranch -Name "add-auth-service"
    Creates feature/add-auth-service from develop.

.EXAMPLE
    New-GitBranch -Name "fix/broken-deploy" -Base main
    Creates fix/broken-deploy from main and switches to it.

.EXAMPLE
    New-GitBranch -Name "hotfix/critical-bug" -NoSwitch
    Creates hotfix/critical-bug but stays on current branch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter()]
    [string]$Base = 'develop',

    [switch]$NoSwitch,

    [Parameter()]
    [string[]]$Prefixes = @('feature', 'fix', 'chore', 'hotfix', 'release', 'experiment')
)

$ErrorActionPreference = 'Stop'

# Auto-prefix if no convention prefix present
$hasPrefix = $false
foreach ($p in $Prefixes) {
    if ($Name.StartsWith("$p/")) {
        $hasPrefix = $true
        break
    }
}
if (-not $hasPrefix) {
    $Name = "feature/$Name"
    Write-Host "  Auto-prefixed branch name: $Name" -ForegroundColor DarkGray
}

# Sanitize branch name
$Name = $Name -replace '[^a-zA-Z0-9/_-]', '-' -replace '-+', '-'

# Ensure we're on the base branch and up to date
Write-Host "  Creating branch '$Name' from '$Base'..." -ForegroundColor Cyan

git fetch origin $Base 2>&1 | Out-Null

if ($NoSwitch) {
    git branch $Name "origin/$Base" 2>&1 | Out-Null
    Write-Host "  ✓ Branch '$Name' created (not switched)" -ForegroundColor Green
} else {
    git checkout -b $Name "origin/$Base" 2>&1 | Out-Null
    Write-Host "  ✓ Switched to new branch '$Name'" -ForegroundColor Green
}

# Show current state
git log --oneline -3
