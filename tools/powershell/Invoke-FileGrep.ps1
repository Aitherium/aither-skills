#Requires -Version 7.0
<#
.SYNOPSIS
    Search for text or regex patterns inside files (content grep).

.DESCRIPTION
    Recursively searches file contents under a root directory, filtering by
    file extension or glob. Returns matching lines with file path, line
    number, and optional surrounding context.

.PARAMETER Path
    Root directory to search in (default: current location).

.PARAMETER Pattern
    Text or regex pattern to look for.

.PARAMETER Filter
    File glob filter, e.g. "*.py", "*.yaml" (default: all files).

.PARAMETER Regex
    Treat -Pattern as a regular expression.

.PARAMETER CaseSensitive
    Use case-sensitive matching (default is case-insensitive).

.PARAMETER ContextLines
    Lines of context before and after each match (default: 0).

.PARAMETER MaxResults
    Maximum number of matches to return (default: 200).

.EXAMPLE
    Invoke-FileGrep -Pattern "TODO" -Path ./src
    Search recursively for "TODO" comments.

.EXAMPLE
    Invoke-FileGrep -Pattern "func\s+\w+\s*\(" -Filter "*.go" -Regex -ContextLines 2
    Find all function declarations in Go files with 2 lines of context.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Pattern,

    [Parameter()]
    [string]$Path = (Get-Location).Path,

    [Parameter()]
    [string]$Filter = '*',

    [switch]$Regex,
    [switch]$CaseSensitive,

    [Parameter()]
    [int]$ContextLines = 0,

    [Parameter()]
    [int]$MaxResults = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path $Path -ErrorAction Stop

Write-Host "🔍 Searching for '$Pattern' in $root ($Filter)..." -ForegroundColor Cyan

$files = Get-ChildItem -Path $root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/]\.' }

$matchCount = 0
$fileCount  = 0

$regexPattern = if ($Regex) { $Pattern } else { [regex]::Escape($Pattern) }
$opts = if ($CaseSensitive) { [System.Text.RegularExpressions.RegexOptions]::None }
        else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }

foreach ($file in $files) {
    try {
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
    } catch { continue }

    $fileCount++
    $fileHits = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([regex]::IsMatch($lines[$i], $regexPattern, $opts)) {
            $ln = $i + 1
            $rel = $file.FullName.Substring($root.Path.Length).TrimStart('\', '/')
            $entry = "  ${rel}:${ln}: $($lines[$i].TrimEnd())"
            $fileHits += $entry

            if ($ContextLines -gt 0) {
                $start = [Math]::Max(0, $i - $ContextLines)
                $end   = [Math]::Min($lines.Count - 1, $i + $ContextLines)
                for ($j = $start; $j -le $end; $j++) {
                    if ($j -ne $i) {
                        $fileHits += "    $($j+1): $($lines[$j].TrimEnd())"
                    }
                }
                $fileHits += ''
            }

            $matchCount++
            if ($matchCount -ge $MaxResults) { break }
        }
    }

    if ($fileHits.Count -gt 0) {
        $fileHits | ForEach-Object { Write-Host $_ }
    }

    if ($matchCount -ge $MaxResults) {
        Write-Warning "Reached max results ($MaxResults). Stopping."
        break
    }
}

Write-Host "`n✅ $matchCount match(es) in $fileCount file(s) searched." -ForegroundColor Green
