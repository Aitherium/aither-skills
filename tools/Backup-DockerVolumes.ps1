#Requires -Version 7.0
<#
.SYNOPSIS
    Snapshot Docker named volumes into compressed archives.

.DESCRIPTION
    Discovers Docker named volumes and creates .tgz archives using an Alpine
    container with read-only volume mounts.

    Each run produces a timestamped subdirectory containing one .tgz per volume
    and a manifest.json with volume names, sizes, timestamps, and archive paths.

    Large or re-downloadable volumes can be excluded via -SkipPattern.

    Old snapshot directories older than -MaxAgeDays are pruned automatically.

.PARAMETER Volume
    Explicit list of volume names to back up. If provided, -Pattern and
    -ComposeFile discovery are skipped.

.PARAMETER Pattern
    Regex to select volumes from `docker volume ls`. Default: '.*' (all named
    volumes). Automatically excludes anonymous 64-hex-char volume IDs.

.PARAMETER SkipPattern
    Regex of volumes to exclude from backup. Default: none.

.PARAMETER ComposeFile
    Path to docker-compose file. If provided, also extract volumes from the
    top-level volumes: block in addition to -Pattern discovery.

.PARAMETER BackupDir
    Root directory for volume snapshots. Default: ./docker-volume-backups

.PARAMETER MaxAgeDays
    Delete snapshot directories older than this many days. Default: 7.

.PARAMETER DryRun
    Show what would be backed up without creating any archives.

.PARAMETER IncludeAll
    Include ALL discovered volumes regardless of -SkipPattern.

.EXAMPLE
    .\Backup-DockerVolumes.ps1
    Back up all named volumes matching default pattern (excludes 64-char IDs).

.EXAMPLE
    .\Backup-DockerVolumes.ps1 -Volume mydb-data, myapp-cache -MaxAgeDays 14
    Back up two specific volumes, keep 14 days of snapshots.

.EXAMPLE
    .\Backup-DockerVolumes.ps1 -Pattern '^myapp-' -SkipPattern 'models|cache' -DryRun
    Preview volumes matching '^myapp-' but not containing 'models' or 'cache'.

.EXAMPLE
    .\Backup-DockerVolumes.ps1 -ComposeFile docker-compose.yml -DryRun
    Preview volumes from compose file + discovered pattern, without archiving.

.NOTES
    Archives are created via: docker run --rm alpine:3.20 tar -czf ...
    Requires Docker Desktop to be running.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Volume,

    [string]$Pattern = '.*',

    [string]$SkipPattern,

    [string]$ComposeFile,

    [string]$BackupDir,

    [ValidateRange(1, 365)]
    [int]$MaxAgeDays = 7,

    [switch]$DryRun,

    [switch]$IncludeAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# HELPERS
# =============================================================================

function Write-Banner {
    param([string]$Title, [string]$Subtitle, [ConsoleColor]$Color = 'Cyan')
    $width = 65
    $rule = [string]::new([char]0x2550, $width - 2)
    Write-Host ""
    Write-Host ([char]0x2554 + $rule + [char]0x2557) -ForegroundColor $Color
    Write-Host ("{0}  {1,-$($width - 4)}  {2}" -f [char]0x2551, $Title, [char]0x2551) -ForegroundColor $Color
    if ($Subtitle) {
        Write-Host ("{0}  {1,-$($width - 4)}  {2}" -f [char]0x2551, $Subtitle, [char]0x2551) -ForegroundColor $Color
    }
    Write-Host ([char]0x255A + $rule + [char]0x255D) -ForegroundColor $Color
    Write-Host ""
}

function Write-Step {
    param([string]$Message, [ConsoleColor]$Color = 'White', [string]$Prefix = '[*]')
    Write-Host "$Prefix $Message" -ForegroundColor $Color
}

function Write-Ok {
    param([string]$Message)
    Write-Step $Message -Color Green -Prefix '[+]'
}

function Write-Warn {
    param([string]$Message)
    Write-Step $Message -Color Yellow -Prefix '[!]'
}

function Write-Err {
    param([string]$Message)
    Write-Step $Message -Color Red -Prefix '[x]'
}

function Format-FileSize {
    <#
    .SYNOPSIS
        Format bytes into a human-readable string.
    #>
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

Write-Banner 'Backup-DockerVolumes' 'Docker Volume Snapshots'

# Verify Docker is running
Write-Step 'Checking Docker daemon...'
try {
    $dockerInfo = docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker info failed" }
    Write-Ok "Docker daemon running (v$dockerInfo)"
} catch {
    Write-Err "Docker is not running. Start Docker and try again."
    exit 1
}

# =============================================================================
# DISCOVER VOLUMES
# =============================================================================

$targetVolumes = @()
$skippedVolumes = @()

if ($Volume) {
    # Explicit volume list provided
    Write-Step "Using explicit volume list ($($Volume.Count) volumes)"
    $targetVolumes = @($Volume)
} else {
    Write-Step 'Discovering volumes...'

    # Parse volumes from compose file if provided
    $composeVolumes = @()
    if ($ComposeFile) {
        if (-not (Test-Path $ComposeFile)) {
            Write-Err "Compose file not found: $ComposeFile"
            exit 1
        }
        Write-Step "Parsing compose file: $ComposeFile"

        $inVolumesBlock = $false
        foreach ($line in (Get-Content $ComposeFile)) {
            # Top-level volumes: key (no leading whitespace)
            if ($line -match '^volumes:\s*$') {
                $inVolumesBlock = $true
                continue
            }
            # Another top-level key ends the block
            if ($inVolumesBlock -and $line -match '^\S' -and $line -notmatch '^\s*#') {
                $inVolumesBlock = $false
                continue
            }
            # Match any two-space-indented "  name:" entry under the volumes: block
            if ($inVolumesBlock -and $line -match '^\s{2}([\w][\w-]*):\s*$' -and $line -notmatch '^\s*#') {
                $composeVolumes += $Matches[1]
            }
        }

        if ($composeVolumes) {
            Write-Ok "Found $($composeVolumes.Count) volumes in compose file"
        }
    }

    # Discover from Docker runtime, matching -Pattern
    $runtimeVolumes = @()
    try {
        $dockerVolOutput = docker volume ls --format '{{.Name}}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Exclude anonymous 64-hex-char volume IDs, apply -Pattern
            $runtimeVolumes = $dockerVolOutput | Where-Object {
                # Skip anonymous volumes (64 hex chars)
                if ($_ -match '^[a-f0-9]{64}$') {
                    return $false
                }
                # Apply pattern
                if ($_ -notmatch $Pattern) {
                    return $false
                }
                return $true
            }
            if ($runtimeVolumes) {
                Write-Ok "Found $($runtimeVolumes.Count) volumes matching pattern '$Pattern' in Docker"
            }
        }
    } catch {
        Write-Warn "Could not list Docker volumes: $_"
    }

    # Merge compose + runtime, deduplicate
    $allVolumes = @($composeVolumes) + @($runtimeVolumes) | Sort-Object -Unique

    # Filter out volumes that don't actually exist in Docker
    $existingVolumes = @()
    foreach ($vol in $allVolumes) {
        $inspectOut = docker volume inspect $vol 2>&1
        if ($LASTEXITCODE -eq 0) {
            $existingVolumes += $vol
        }
    }

    Write-Ok "$($existingVolumes.Count) volumes exist in Docker"

    # Apply skip filters
    foreach ($vol in $existingVolumes) {
        if ($IncludeAll) {
            $targetVolumes += $vol
            continue
        }

        # Check skip pattern
        if ($SkipPattern -and $vol -match $SkipPattern) {
            $skippedVolumes += $vol
            continue
        }

        $targetVolumes += $vol
    }
}

if ($skippedVolumes.Count -gt 0) {
    Write-Warn "Skipping $($skippedVolumes.Count) volume(s) matching skip pattern: $($skippedVolumes -join ', ')"
    Write-Step "  Use -IncludeAll to override" -Color DarkGray
}

if ($targetVolumes.Count -eq 0) {
    Write-Warn "No volumes to back up."
    exit 0
}

Write-Ok "Will snapshot $($targetVolumes.Count) volumes"

# =============================================================================
# INSPECT VOLUME SIZES (for manifest and dry-run)
# =============================================================================

Write-Step 'Inspecting volume sizes...'

$volumeInfo = @()
foreach ($vol in $targetVolumes) {
    # Estimate size via du in a container
    $sizeBytes = 0
    try {
        $duOutput = docker run --rm -v "${vol}:/source:ro" alpine:3.20 du -sb /source 2>&1
        if ($LASTEXITCODE -eq 0 -and $duOutput -match '^(\d+)') {
            $sizeBytes = [long]$Matches[1]
        }
    } catch {
        # Silently continue; size will be 0
    }

    $volumeInfo += [PSCustomObject]@{
        Name      = $vol
        SizeBytes = $sizeBytes
        SizeHuman = Format-FileSize $sizeBytes
    }
}

# Display volume table
Write-Host ""
Write-Host "  Volume                              Size" -ForegroundColor Cyan
Write-Host "  ------------------------------------  -----------" -ForegroundColor DarkGray
foreach ($vi in ($volumeInfo | Sort-Object -Property SizeBytes -Descending)) {
    $nameFormatted = $vi.Name.PadRight(36)
    Write-Host "  $nameFormatted  $($vi.SizeHuman)" -ForegroundColor White
}

$totalBytes = ($volumeInfo | Measure-Object -Property SizeBytes -Sum).Sum
Write-Host ""
Write-Step "Total data size: $(Format-FileSize $totalBytes)" -Color Cyan

# =============================================================================
# DRY RUN EXIT
# =============================================================================

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($DryRun) {
    Write-Host ""
    Write-Banner 'DRY RUN COMPLETE' 'No archives were created.' -Color Yellow
    Write-Step "Would create snapshot in: $BackupDir\$Timestamp" -Color Yellow
    Write-Step "Would archive $($targetVolumes.Count) volumes ($(Format-FileSize $totalBytes) uncompressed)" -Color Yellow
    exit 0
}

# =============================================================================
# RESOLVE BACKUP DIRECTORY
# =============================================================================

if (-not $BackupDir) {
    $BackupDir = Join-Path (Get-Location) 'docker-volume-backups'
}

Write-Step "Backup root: $BackupDir"

# =============================================================================
# CREATE SNAPSHOT DIRECTORY
# =============================================================================

$snapshotDir = Join-Path $BackupDir $Timestamp

if ($PSCmdlet.ShouldProcess($snapshotDir, 'Create snapshot directory')) {
    if (-not (Test-Path $snapshotDir)) {
        New-Item -Path $snapshotDir -ItemType Directory -Force | Out-Null
    }
    Write-Ok "Snapshot directory: $snapshotDir"
}

# =============================================================================
# ARCHIVE EACH VOLUME
# =============================================================================

Write-Host ""
Write-Step 'Creating archives...'
Write-Host ""

$manifest = @{
    timestamp      = (Get-Date -Format 'o')
    snapshot_id    = $Timestamp
    backup_dir     = $snapshotDir
    volumes        = @()
    total_bytes    = 0
    total_archive  = 0
    duration_sec   = 0
    skipped        = $skippedVolumes
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$successCount = 0
$failCount = 0

foreach ($vi in $volumeInfo) {
    $vol = $vi.Name
    $archiveName = "$vol.tgz"
    $archivePath = Join-Path $snapshotDir $archiveName

    $dockerBackupDir = $snapshotDir -replace '\\', '/'

    $progressMsg = "  [$($successCount + $failCount + 1)/$($volumeInfo.Count)] $vol ($($vi.SizeHuman))..."
    Write-Host $progressMsg -ForegroundColor White -NoNewline

    if (-not $PSCmdlet.ShouldProcess($vol, 'Archive Docker volume')) {
        Write-Host " skipped (WhatIf)" -ForegroundColor Yellow
        continue
    }

    $volSw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Run tar inside Alpine with the volume mounted read-only
        $dockerArgs = @(
            'run', '--rm',
            '-v', "${vol}:/source:ro",
            '-v', "${dockerBackupDir}:/backup",
            'alpine:3.20',
            'tar', '-czf', "/backup/$archiveName", '-C', '/source', '.'
        )

        $proc = Start-Process -FilePath 'docker' -ArgumentList $dockerArgs `
            -NoNewWindow -Wait -PassThru -RedirectStandardError (Join-Path $env:TEMP "docker-backup-err-$vol.txt")

        $volSw.Stop()

        if ($proc.ExitCode -ne 0) {
            $errFile = Join-Path $env:TEMP "docker-backup-err-$vol.txt"
            $errText = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { 'unknown error' }
            throw "docker tar exited $($proc.ExitCode): $errText"
        }

        # Get archive size
        $archiveSize = 0
        if (Test-Path $archivePath) {
            $archiveSize = (Get-Item $archivePath).Length
        }

        $manifest.volumes += @{
            name          = $vol
            archive       = $archiveName
            archive_path  = $archivePath
            source_bytes  = $vi.SizeBytes
            archive_bytes = $archiveSize
            archive_human = Format-FileSize $archiveSize
            duration_sec  = [math]::Round($volSw.Elapsed.TotalSeconds, 1)
            status        = 'ok'
        }

        $manifest.total_archive += $archiveSize
        $successCount++

        $ratio = if ($vi.SizeBytes -gt 0) { [math]::Round(($archiveSize / $vi.SizeBytes) * 100) } else { 0 }
        Write-Host " $(Format-FileSize $archiveSize) (${ratio}% ratio, $([math]::Round($volSw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Green

    } catch {
        $volSw.Stop()
        $failCount++
        Write-Host " FAILED" -ForegroundColor Red
        Write-Err "  $($_.Exception.Message)"

        $manifest.volumes += @{
            name         = $vol
            archive      = $archiveName
            source_bytes = $vi.SizeBytes
            duration_sec = [math]::Round($volSw.Elapsed.TotalSeconds, 1)
            status       = 'failed'
            error        = $_.Exception.Message
        }
    }
}

$sw.Stop()
$manifest.total_bytes = $totalBytes
$manifest.duration_sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

# =============================================================================
# WRITE MANIFEST
# =============================================================================

$manifestPath = Join-Path $snapshotDir 'manifest.json'

if ($PSCmdlet.ShouldProcess($manifestPath, 'Write manifest')) {
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding utf8
    Write-Host ""
    Write-Ok "Manifest written: $manifestPath"
}

# =============================================================================
# CLEANUP OLD SNAPSHOTS
# =============================================================================

Write-Host ""
Write-Step "Pruning snapshots older than $MaxAgeDays days..."

$cutoff = (Get-Date).AddDays(-$MaxAgeDays)
$pruned = 0

if (Test-Path $BackupDir) {
    $oldDirs = Get-ChildItem -Path $BackupDir -Directory | Where-Object {
        # Match timestamp-named directories (yyyyMMdd-HHmmss)
        $_.Name -match '^\d{8}-\d{6}$' -and $_.CreationTime -lt $cutoff
    }

    foreach ($oldDir in $oldDirs) {
        if ($PSCmdlet.ShouldProcess($oldDir.FullName, 'Remove old snapshot')) {
            try {
                Remove-Item -Path $oldDir.FullName -Recurse -Force
                $pruned++
                Write-Step "  Removed: $($oldDir.Name)" -Color DarkGray
            } catch {
                Write-Warn "  Failed to remove $($oldDir.Name): $_"
            }
        }
    }
}

if ($pruned -gt 0) {
    Write-Ok "Pruned $pruned old snapshot(s)"
} else {
    Write-Step "No old snapshots to prune"
}

# =============================================================================
# SUMMARY
# =============================================================================

Write-Host ""
$summaryColor = if ($failCount -eq 0) { 'Green' } else { 'Yellow' }

Write-Banner 'Backup Complete' '' -Color $summaryColor

Write-Host "  Volumes archived:    $successCount / $($volumeInfo.Count)" -ForegroundColor $summaryColor
if ($failCount -gt 0) {
    Write-Host "  Volumes failed:      $failCount" -ForegroundColor Red
}
if ($skippedVolumes.Count -gt 0) {
    Write-Host "  Volumes skipped:     $($skippedVolumes.Count)" -ForegroundColor DarkGray
}
Write-Host "  Uncompressed total:  $(Format-FileSize $totalBytes)" -ForegroundColor White
Write-Host "  Archive total:       $(Format-FileSize $manifest.total_archive)" -ForegroundColor White
$overallRatio = if ($totalBytes -gt 0) { [math]::Round(($manifest.total_archive / $totalBytes) * 100) } else { 0 }
Write-Host "  Compression ratio:   ${overallRatio}%" -ForegroundColor White
Write-Host "  Duration:            $($manifest.duration_sec)s" -ForegroundColor White
Write-Host "  Snapshot directory:  $snapshotDir" -ForegroundColor Cyan
Write-Host "  Manifest:            $manifestPath" -ForegroundColor Cyan
Write-Host "  Old snapshots pruned: $pruned" -ForegroundColor White
Write-Host ""
