#Requires -Version 7.0
<#
.SYNOPSIS
    Find and replace text across multiple files matching a glob pattern.

.DESCRIPTION
    Recursively searches files under a directory, filters by glob, and
    performs a find/replace in each matching file. Supports plain-text and
    regex. Use -DryRun to preview without writing.

.PARAMETER Find
    Text or regex to search for.

.PARAMETER Replace
    Replacement text (supports $1, $2 backreferences when -Regex is used).

.PARAMETER Path
    Root directory to search in (default: current location).

.PARAMETER Filter
    File glob filter, e.g. "*.yaml" (default: all files).

.PARAMETER Regex
    Treat -Find as a regular expression.

.PARAMETER CaseSensitive
    Use case-sensitive matching (default: case-insensitive).

.PARAMETER DryRun
    Preview which files would be changed without writing.

.PARAMETER MaxFiles
    Maximum files to modify (safety limit, default: 50).

.EXAMPLE
    Invoke-BulkReplace -Find "oldName" -Replace "newName" -Filter "*.ts" -DryRun
    Preview changes to all TypeScript files.

.EXAMPLE
    Invoke-BulkReplace -Find "(\d{4})-(\d{2})-(\d{2})" -Replace "$3/$2/$1" -Regex -Path ./data
    Convert date format from YYYY-MM-DD to DD/MM/YYYY in ./data tree.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Find,

    [Parameter(Mandatory)]
    [string]$Replace,

    [Parameter()]
    [string]$Path = (Get-Location).Path,

    [Parameter()]
    [string]$Filter = '*',

    [switch]$Regex,
    [switch]$CaseSensitive,
    [switch]$DryRun,

    [Parameter()]
    [int]$MaxFiles = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path $Path -ErrorAction Stop
Write-Host "🔄 Bulk replace '$Find' → '$Replace' in $root ($Filter)" -ForegroundColor Cyan

$regexPattern = if ($Regex) { $Find } else { [regex]::Escape($Find) }
$opts = if ($CaseSensitive) { [System.Text.RegularExpressions.RegexOptions]::None }
        else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }

$files = Get-ChildItem -Path $root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/]\.' }

$modified = 0
$totalReplacements = 0

foreach ($file in $files) {
    if ($modified -ge $MaxFiles) {
        Write-Warning "Reached max files ($MaxFiles). Stopping."
        break
    }
    try {
        $content = [System.IO.File]::ReadAllText($file.FullName)
    } catch { continue }

    $matches = [regex]::Matches($content, $regexPattern, $opts)
    if ($matches.Count -eq 0) { continue }

    $rel = $file.FullName.Substring($root.Path.Length).TrimStart('\', '/')
    $count = $matches.Count

    if ($DryRun) {
        Write-Host "  [DRY] $rel — $count replacement(s)" -ForegroundColor Yellow
    } else {
        if ($PSCmdlet.ShouldProcess($file.FullName, "Replace $count occurrence(s)")) {
            $newContent = [regex]::Replace($content, $regexPattern, $Replace, $opts)
            [System.IO.File]::WriteAllText($file.FullName, $newContent)
            Write-Host "  ✏️  $rel — $count replacement(s)" -ForegroundColor Green
        }
    }

    $modified++
    $totalReplacements += $count
}

$verb = if ($DryRun) { 'Would replace' } else { 'Replaced' }
Write-Host "`n✅ $verb $totalReplacements occurrence(s) across $modified file(s)." -ForegroundColor Green
