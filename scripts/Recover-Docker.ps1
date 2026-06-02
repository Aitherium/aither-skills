<#
.SYNOPSIS
    Recovers Docker Desktop from the WSL2 500-error hang without rebooting.
.DESCRIPTION
    When Docker Desktop's Linux engine wedges (API returns 500), this script:
    1. Kills Docker Desktop and all related processes
    2. Shuts down WSL completely
    3. Stops the Docker and WSL Windows services
    4. Restarts everything cleanly
    Can also run as a scheduled task to auto-detect and recover.
.PARAMETER Monitor
    Run in monitoring loop — checks every 30s, auto-recovers on failure.
.PARAMETER Interval
    Seconds between health checks in monitor mode (default: 30).
#>
param(
    [switch]$Monitor,
    [int]$Interval = 30
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-DockerHealthy {
    try {
        $result = docker info 2>&1
        if ($LASTEXITCODE -ne 0 -or $result -match '500 Internal Server Error') {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Invoke-DockerRecovery {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] Docker engine is DOWN. Starting recovery..." -ForegroundColor Red

    # Phase 1: Kill Docker Desktop UI processes
    Write-Host "  [1/5] Killing Docker Desktop processes..." -ForegroundColor Yellow
    Stop-Process -Name 'Docker Desktop' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'com.docker.backend' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'com.docker.build' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'docker-agent' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'docker-sandbox' -Force -ErrorAction SilentlyContinue
    Start-Sleep 2

    # Phase 2: Shut down WSL (kills the hung Linux VM)
    Write-Host "  [2/5] Shutting down WSL..." -ForegroundColor Yellow
    wsl --shutdown 2>$null
    Start-Sleep 3

    # Phase 3: Kill any remaining zombie processes
    Write-Host "  [3/5] Cleaning up zombie processes..." -ForegroundColor Yellow
    taskkill /F /IM 'vmmem' 2>$null
    taskkill /F /IM 'wslservice.exe' 2>$null
    Start-Sleep 2

    # Phase 4: Stop and restart Windows services (needs admin)
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Host "  [4/5] Restarting Docker Windows service..." -ForegroundColor Yellow
        Stop-Service 'com.docker.service' -Force -ErrorAction SilentlyContinue
        Stop-Service 'wslservice' -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
        Start-Service 'com.docker.service' -ErrorAction SilentlyContinue
    } else {
        Write-Host "  [4/5] Skipping service restart (not admin). If this doesn't work, run as admin." -ForegroundColor DarkYellow
    }
    Start-Sleep 2

    # Phase 5: Restart Docker Desktop
    Write-Host "  [5/5] Starting Docker Desktop..." -ForegroundColor Yellow
    Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

    # Wait for engine to come back
    Write-Host "  Waiting for Docker engine..." -ForegroundColor Cyan
    $maxWait = 90
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep 5
        $waited += 5
        if (Test-DockerHealthy) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Write-Host "[$timestamp] Docker recovered in ${waited}s!" -ForegroundColor Green

            # Check for dead containers and restart them
            $dead = docker ps -a --filter "status=dead" --format "{{.Names}}" 2>$null
            if ($dead) {
                Write-Host "  Cleaning up dead containers: $($dead -join ', ')" -ForegroundColor Yellow
                foreach ($c in $dead) {
                    docker rm -f $c 2>$null
                }
            }

            # Restart exited containers that have restart policy
            $exited = docker ps -a --filter "status=exited" --format "{{.Names}}" 2>$null
            if ($exited) {
                Write-Host "  Restarting exited containers..." -ForegroundColor Yellow
                foreach ($c in $exited) {
                    docker start $c 2>$null
                }
            }

            return $true
        }
        Write-Host "  ... ${waited}s elapsed" -ForegroundColor DarkGray
    }

    Write-Host "[$timestamp] Recovery FAILED after ${maxWait}s. You may need to reboot." -ForegroundColor Red
    return $false
}

# --- Main ---

if ($Monitor) {
    Write-Host "Docker health monitor started (checking every ${Interval}s). Ctrl+C to stop." -ForegroundColor Cyan
    while ($true) {
        if (-not (Test-DockerHealthy)) {
            Invoke-DockerRecovery
        }
        Start-Sleep $Interval
    }
} else {
    if (Test-DockerHealthy) {
        Write-Host "Docker engine is healthy. Nothing to do." -ForegroundColor Green
        docker ps --format "table {{.Names}}`t{{.Status}}" | Select-Object -First 20
    } else {
        Invoke-DockerRecovery
    }
}
