#Requires -Version 7.0
<#
.SYNOPSIS
    Stages and commits changes with a conventional commit message.

.DESCRIPTION
    Stages specified files (or all changes) and creates a commit following
    the Conventional Commits format (https://www.conventionalcommits.org/).

    Allowed commit types: feat, fix, chore, docs, refactor, test, ci, perf, build, style, revert

.PARAMETER Message
    Commit message. Should follow conventional format: type(scope): description
    Example: feat(auth): add OAuth2 login

.PARAMETER Files
    Specific files/patterns to stage. If omitted, stages all changes.

.PARAMETER Push
    Push to remote after committing.

.PARAMETER Remote
    Remote to push to. Default: origin

.PARAMETER Branch
    Branch to push. If omitted, uses current branch.

.EXAMPLE
    New-GitCommit -Message "feat(api): add user endpoints"
    Stage all changes and commit with conventional message.

.EXAMPLE
    New-GitCommit -Message "fix: typo in README" -Files "README.md" -Push
    Commit specific file and push to origin.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Message,

    [Parameter()]
    [string]$Files,

    [switch]$Push,

    [string]$Remote = 'origin',

    [string]$Branch
)

$ErrorActionPreference = 'Stop'

# Validate conventional commit format (advisory)
$conventionalPattern = '^(feat|fix|chore|docs|refactor|test|ci|perf|build|style|revert)(\(.+\))?(!)?:\s.+'
if ($Message -notmatch $conventionalPattern) {
    Write-Host "  ⚠ Message doesn't follow conventional commits format" -ForegroundColor Yellow
    Write-Host "    Expected: type(scope): description" -ForegroundColor DarkGray
    Write-Host "    Example:  feat(deploy): add ring promotion" -ForegroundColor DarkGray
}

# Stage files
if ($Files) {
    $fileList = $Files -split '[,;]' | ForEach-Object { $_.Trim() }
    foreach ($f in $fileList) {
        git add $f 2>&1 | Out-Null
    }
    Write-Host "  Staged $($fileList.Count) path(s)" -ForegroundColor Gray
} else {
    git add -A 2>&1 | Out-Null
    Write-Host "  Staged all changes" -ForegroundColor Gray
}

# Check for changes
$staged = git diff --cached --stat
if (-not $staged) {
    Write-Host "  ℹ Nothing to commit (working tree clean)" -ForegroundColor Yellow
    exit 0
}

Write-Host "  Changes to commit:" -ForegroundColor Cyan
$staged | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

# Commit
git commit -m $Message 2>&1 | Out-Null
$commitHash = git rev-parse --short HEAD
Write-Host "  ✓ Committed: $commitHash $Message" -ForegroundColor Green

# Push if requested
if ($Push) {
    if (-not $Branch) {
        $Branch = git symbolic-ref --short HEAD
    }
    Write-Host "  Pushing to $Remote/$Branch..." -ForegroundColor Cyan
    git push $Remote $Branch 2>&1 | Out-Null
    Write-Host "  ✓ Pushed to $Remote/$Branch" -ForegroundColor Green
}
