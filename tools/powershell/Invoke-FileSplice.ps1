#Requires -Version 7.0
<#
.SYNOPSIS
    Splice (replace) a range of lines in a target file with content from a source file or inline text.

.DESCRIPTION
    Performs a surgical line-range replacement on a text file.

    Modes:
      -SourceFile   : Replace target lines with the entire content of a source file
      -Content      : Replace target lines with the provided string
      -DeleteOnly   : Just remove the line range (no replacement)

    Exit Codes:
      0 - Success
      1 - Validation failure (missing file, bad range)
      2 - Execution error

.PARAMETER TargetFile
    Path to the file being modified (required).

.PARAMETER StartLine
    First line to replace (1-indexed, inclusive, required).

.PARAMETER EndLine
    Last line to replace (1-indexed, inclusive, required).

.PARAMETER SourceFile
    Path to a file whose content replaces the target range.

.PARAMETER Content
    Inline string content to splice in (alternative to -SourceFile).

.PARAMETER DeleteOnly
    Remove the line range without inserting replacement content.

.PARAMETER Encoding
    File encoding (default: UTF8).

.PARAMETER DryRun
    Show what would happen without writing.

.PARAMETER PassThru
    Return the result object instead of writing host output.

.EXAMPLE
    Invoke-FileSplice -TargetFile worker.js -SourceFile patch.js -StartLine 104 -EndLine 284
    Replace lines 104-284 of worker.js with patch.js content.

.EXAMPLE
    Invoke-FileSplice -TargetFile config.yaml -StartLine 10 -EndLine 10 -Content "key: new_value"
    Replace a single line with inline content.

.EXAMPLE
    Invoke-FileSplice -TargetFile worker.js -SourceFile patch.js -StartLine 50 -EndLine 100 -DryRun
    Preview what would be changed.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'FromFile')]
param(
    [Parameter(Mandatory)]
    [string]$TargetFile,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$StartLine,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$EndLine,

    [Parameter(ParameterSetName = 'FromFile')]
    [string]$SourceFile,

    [Parameter(ParameterSetName = 'Inline')]
    [string]$Content,

    [Parameter(ParameterSetName = 'Delete')]
    [switch]$DeleteOnly,

    [string]$Encoding = 'UTF8',
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Resolve paths ────────────────────────────────────────────────────────────
$TargetFile = (Resolve-Path -Path $TargetFile -ErrorAction Stop).Path

if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
    if (-not $SourceFile) {
        Write-Error "Must provide -SourceFile, -Content, or -DeleteOnly"
        exit 1
    }
    $SourceFile = (Resolve-Path -Path $SourceFile -ErrorAction Stop).Path
}

# ── Validate ─────────────────────────────────────────────────────────────────
if (-not (Test-Path $TargetFile -PathType Leaf)) {
    Write-Error "Target file not found: $TargetFile"
    exit 1
}

if ($EndLine -lt $StartLine) {
    Write-Error "EndLine ($EndLine) must be >= StartLine ($StartLine)"
    exit 1
}

# ── Read target ──────────────────────────────────────────────────────────────
$lines = [System.IO.File]::ReadAllLines($TargetFile, [System.Text.Encoding]::$Encoding)
$totalBefore = $lines.Count

if ($StartLine -gt $totalBefore) {
    Write-Error "StartLine ($StartLine) exceeds file length ($totalBefore lines)"
    exit 1
}

$effectiveEnd = [Math]::Min($EndLine, $totalBefore)
$linesRemoved = $effectiveEnd - $StartLine + 1

# ── Build new content ────────────────────────────────────────────────────────
switch ($PSCmdlet.ParameterSetName) {
    'FromFile' {
        if (-not (Test-Path $SourceFile -PathType Leaf)) {
            Write-Error "Source file not found: $SourceFile"
            exit 1
        }
        $newLines = [System.IO.File]::ReadAllLines($SourceFile, [System.Text.Encoding]::$Encoding)
    }
    'Inline' {
        $newLines = $Content -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    }
    'Delete' {
        $newLines = @()
    }
}

$linesInserted = $newLines.Count

# ── Splice ───────────────────────────────────────────────────────────────────
# prefix = lines[0 .. StartLine-2], suffix = lines[effectiveEnd .. end]
$prefix = if ($StartLine -gt 1) { $lines[0..($StartLine - 2)] } else { @() }
$suffix = if ($effectiveEnd -lt $totalBefore) { $lines[$effectiveEnd..($totalBefore - 1)] } else { @() }

$result = @()
$result += $prefix
$result += $newLines
$result += $suffix

$totalAfter = $result.Count

# ── Result object ────────────────────────────────────────────────────────────
$output = [PSCustomObject]@{
    TargetFile      = $TargetFile
    SourceFile      = if ($PSCmdlet.ParameterSetName -eq 'FromFile') { $SourceFile } else { $null }
    LinesRemoved    = $linesRemoved
    LinesInserted   = $linesInserted
    TotalBefore     = $totalBefore
    TotalAfter      = $totalAfter
    RangeReplaced   = "${StartLine}-${effectiveEnd}"
    DryRun          = [bool]$DryRun
}

# ── Write or preview ─────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host "╔═══ DRY RUN ═══════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║ Target   : $TargetFile" -ForegroundColor Yellow
    if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
        Write-Host "║ Source   : $SourceFile" -ForegroundColor Yellow
    }
    Write-Host "║ Range    : lines $StartLine – $effectiveEnd ($linesRemoved lines)" -ForegroundColor Yellow
    Write-Host "║ Inserting: $linesInserted lines" -ForegroundColor Yellow
    Write-Host "║ Before   : $totalBefore lines  →  After: $totalAfter lines" -ForegroundColor Yellow
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
}
else {
    if ($PSCmdlet.ShouldProcess($TargetFile, "Splice lines $StartLine-$effectiveEnd")) {
        [System.IO.File]::WriteAllLines($TargetFile, $result, [System.Text.Encoding]::$Encoding)
        Write-Host "✓ Spliced $TargetFile : replaced lines $StartLine–$effectiveEnd ($linesRemoved → $linesInserted lines). Total: $totalBefore → $totalAfter" -ForegroundColor Green
    }
}

if ($PassThru) { $output }

exit 0
