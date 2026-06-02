#Requires -Version 7.0
<#
.SYNOPSIS
    Compare two files or a file vs inline string and show a unified diff.

.DESCRIPTION
    Produces a unified diff between two files or between a file and inline
    content. Shows additions, deletions, and context.

.PARAMETER FileA
    Path to the first (original) file.

.PARAMETER FileB
    Path to the second file to compare against.

.PARAMETER ContentB
    Inline string to compare against FileA (used when FileB is omitted).

.PARAMETER ContextLines
    Number of context lines around changes (default: 3).

.EXAMPLE
    Invoke-FileDiff -FileA old.txt -FileB new.txt
    Compare two files.

.EXAMPLE
    Invoke-FileDiff -FileA config.yaml -ContentB "key: new_value"
    Compare a file to inline content.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FileA,

    [Parameter(ParameterSetName = 'FileDiff')]
    [string]$FileB,

    [Parameter(ParameterSetName = 'InlineDiff')]
    [string]$ContentB,

    [Parameter()]
    [int]$ContextLines = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedA = Resolve-Path $FileA -ErrorAction Stop
if (-not (Test-Path $resolvedA -PathType Leaf)) {
    throw "Not a file: $FileA"
}

$linesA = [System.IO.File]::ReadAllLines($resolvedA.Path)

if ($PSCmdlet.ParameterSetName -eq 'FileDiff' -or $FileB) {
    $resolvedB = Resolve-Path $FileB -ErrorAction Stop
    if (-not (Test-Path $resolvedB -PathType Leaf)) {
        throw "Not a file: $FileB"
    }
    $linesB = [System.IO.File]::ReadAllLines($resolvedB.Path)
    $labelB = $FileB
} elseif ($ContentB) {
    $linesB = $ContentB -split "`n"
    $labelB = '<inline>'
} else {
    throw "Provide either -FileB or -ContentB."
}

# Simple unified-diff style output
$maxLen = [Math]::Max($linesA.Count, $linesB.Count)
$adds = 0; $dels = 0

Write-Host "--- $FileA" -ForegroundColor Red
Write-Host "+++ $labelB" -ForegroundColor Green
Write-Host ""

for ($i = 0; $i -lt $maxLen; $i++) {
    $a = if ($i -lt $linesA.Count) { $linesA[$i] } else { $null }
    $b = if ($i -lt $linesB.Count) { $linesB[$i] } else { $null }

    if ($a -ceq $b) {
        Write-Host " $a"
    } else {
        if ($null -ne $a) {
            Write-Host "-$a" -ForegroundColor Red
            $dels++
        }
        if ($null -ne $b) {
            Write-Host "+$b" -ForegroundColor Green
            $adds++
        }
    }
}

Write-Host ""
if ($adds -eq 0 -and $dels -eq 0) {
    Write-Host "✅ Files are identical." -ForegroundColor Green
} else {
    Write-Host "📊 $adds addition(s), $dels deletion(s)" -ForegroundColor Yellow
}
