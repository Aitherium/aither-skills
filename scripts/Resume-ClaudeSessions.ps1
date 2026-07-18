#Requires -Version 7.0
<#
.SYNOPSIS
    Resume-ClaudeSessions — reopen killed Claude Code sessions across all your
    projects in one shot, each in its own Windows Terminal tab.

.DESCRIPTION
    After a reboot / crash you normally have to open N terminals, cd into each
    project, run `claude`, then `/resume` and hunt for the right conversation.

    This script reads Claude Code's own session journals
    (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl), recovers each
    session's AI title, last prompt, working directory and last-active time,
    lets you pick which to bring back, and launches `claude --resume <id>` for
    each — as tabs in a single Windows Terminal window (default) or as
    separate windows.

    It is read-only against your session history; it never mutates the journals.

.PARAMETER ProjectsRoot
    Root of Claude Code's per-project session store. Default: ~/.claude/projects

.PARAMETER Scan
    How many of the most-recently-written journals to deep-parse for metadata.
    Default 60. Raise if you juggle many projects.

.PARAMETER Top
    Max sessions to display after filtering/sorting. Default 25.

.PARAMETER LookbackHours
    Only consider sessions active within this many hours. 0 = no time filter.

.PARAMETER Filter
    Case-insensitive substring matched against title / cwd / last-prompt.

.PARAMETER PerDir
    Collapse to a single (most-recent) session per working directory.
    Best for "reopen each of my workspaces" without duplicate tabs.

.PARAMETER Select
    Non-interactive selection by LIST POSITION, e.g. "1,3,5-7" or "all". Skips the
    prompt. Safe only within a single invocation (the interactive picker). Any tool
    that lists in one call and launches in another must use -SelectId instead —
    the list re-sorts as journals are written, so position N is not stable across
    processes.

.PARAMETER SelectId
    Non-interactive selection by SESSION ID (comma/space separated) — the stable,
    race-free way to choose. Ids come from -Json output. Exits non-zero if any id
    is not among the candidates rather than silently resuming a subset.

.PARAMETER All
    Launch every displayed session (after filters). Skips the prompt.

.PARAMETER Json
    Emit the candidate sessions as JSON and exit (no launch). For the
    /resume-all Claude command and other tooling.

.PARAMETER SeparateWindows
    Open each resumed session in its own Windows Terminal window instead of
    tabs in one window.

.PARAMETER Tmux
    Resume into tmux windows instead of a GUI terminal. Works on any OS, and is
    the only backend that survives an SSH disconnect — use it when driving this
    from a phone or a remote shell. Auto-selected on Linux when no GUI terminal
    is available.

.PARAMETER TmuxSession
    Name of the tmux session to create/reuse with -Tmux. Default: claude

.PARAMETER IncludeMissing
    Include sessions whose working directory no longer exists (skipped by default).

.PARAMETER ExcludeSession
    Session id to omit (e.g. the session you're calling this from).

.PARAMETER DryRun
    Print what would launch without spawning anything.

.EXAMPLE
    pwsh -File Resume-ClaudeSessions.ps1
    Interactive picker of recent sessions; resume the ones you choose as WT tabs.

.EXAMPLE
    pwsh -File Resume-ClaudeSessions.ps1 -PerDir -All
    Reopen the most-recent session for every project directory, no prompt.

.EXAMPLE
    pwsh -File Resume-ClaudeSessions.ps1 -Filter aither -LookbackHours 24
    Only sessions touching "aither" in the last day.
#>
[CmdletBinding()]
param(
    [string]$ProjectsRoot = (Join-Path $HOME '.claude/projects'),
    [int]$Scan = 60,
    [int]$Top = 25,
    [double]$LookbackHours = 0,
    [string]$Filter,
    [switch]$PerDir,
    [string]$Select,
    [string]$SelectId,
    [switch]$All,
    [switch]$Json,
    [switch]$SeparateWindows,
    [switch]$Tmux,
    [string]$TmuxSession = 'claude',
    [switch]$IncludeMissing,
    [string]$ExcludeSession,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- ANSI helpers (degrade gracefully if not a console) ---------------------
$script:UseColor = -not $Json -and -not [Console]::IsOutputRedirected
function C([string]$code, [string]$text) {
    if ($script:UseColor) { "$([char]27)[${code}m$text$([char]27)[0m" } else { $text }
}

function Get-ClaudeSessionMeta {
    <# Recover a session's metadata from the tail of its journal. Claude rewrites
       the latest ai-title / last-prompt / cwd / timestamp near the end, so a
       bounded tail read is both fast (works on multi-MB files) and accurate. #>
    param([string]$Path)

    $id     = [IO.Path]::GetFileNameWithoutExtension($Path)
    $title  = $null; $lastPrompt = $null; $cwd = $null; $ts = $null; $branch = $null

    try {
        $tail = Get-Content -LiteralPath $Path -Tail 120 -ErrorAction Stop
    } catch { $tail = @() }

    foreach ($line in $tail) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $o = $line | ConvertFrom-Json -Depth 8 } catch { continue }
        switch ($o.type) {
            'ai-title'    { if ($o.aiTitle)    { $title = $o.aiTitle } }
            'last-prompt' { if ($o.lastPrompt) { $lastPrompt = $o.lastPrompt } }
        }
        if ($o.cwd)        { $cwd = $o.cwd }
        if ($o.timestamp)  { $ts = $o.timestamp }
        if ($o.gitBranch)  { $branch = $o.gitBranch }
    }

    if (-not $title) { $title = $id.Substring(0, [Math]::Min(8, $id.Length)) }

    # Prompts routinely carry pasted terminal output with raw control bytes (ESC,
    # etc), and a journal's lastPrompt is not guaranteed to be a plain string.
    # ConvertTo-Json emits such bytes verbatim, which every strict JSON parser then
    # rejects — breaking -Json mode on precisely the sessions worth resuming.
    $strip = {
        param($s)
        if ($null -eq $s) { return $null }
        ([string]$s -replace '[\x00-\x1F\x7F]', ' ' -replace ' {2,}', ' ').Trim()
    }
    $title      = & $strip $title
    $lastPrompt = & $strip $lastPrompt

    $when = $null
    if ($ts) {
        $parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($ts, [ref]$parsed)) { $when = $parsed.LocalDateTime }
    }

    [pscustomobject]@{
        Id         = $id
        Title      = $title
        LastPrompt = $lastPrompt
        Cwd        = $cwd
        Branch     = $branch
        When       = $when
        File       = $Path
    }
}

function Format-Age {
    param([Nullable[datetime]]$When)
    if (-not $When) { return '   ?   ' }
    $span = (Get-Date) - $When
    if ($span.TotalSeconds -lt 0) { $span = [TimeSpan]::Zero }
    if     ($span.TotalMinutes -lt 1)  { 'just now' }
    elseif ($span.TotalMinutes -lt 60) { '{0:0}m ago'  -f $span.TotalMinutes }
    elseif ($span.TotalHours   -lt 24) { '{0:0}h ago'  -f $span.TotalHours }
    else                               { '{0:0}d ago'  -f $span.TotalDays }
}

function Expand-Selection {
    <# "1,3,5-7" / "all" / "a" -> array of 1-based indices #>
    param([string]$Spec, [int]$Count)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return @() }
    if ($Spec -match '^\s*(a|all)\s*$') { return 1..$Count }
    $out = [System.Collections.Generic.List[int]]::new()
    foreach ($tok in ($Spec -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            $a..$b | ForEach-Object { $out.Add($_) }
        } elseif ($tok -match '^\d+$') {
            $out.Add([int]$tok)
        }
    }
    $out | Where-Object { $_ -ge 1 -and $_ -le $Count } | Select-Object -Unique
}

# --- Gather candidates ------------------------------------------------------
if (-not (Test-Path -LiteralPath $ProjectsRoot)) {
    Write-Error "Claude projects root not found: $ProjectsRoot"
    exit 2
}

$uuidRe = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# -SelectId short-circuit. A session id IS its journal's filename, so resolve the
# files directly and SKIP the candidate scan entirely. That scan walks ~10k journals
# and tail-parses -Scan of them (tens of seconds) — pure latency on a launch call,
# which is the one path a human is actually waiting on (worse over a phone/tunnel).
# It also keeps -SelectId independent of -Scan/-Top/-Filter, so an id picked from a
# deep listing always resolves.
$selectedById = $null
if ($SelectId) {
    $wanted  = @($SelectId -split '[,\s]+' | Where-Object { $_ })
    $found   = @()
    $missing = @()
    foreach ($id in $wanted) {
        $jf = $null
        if ($id -match $uuidRe) {
            $jf = Get-ChildItem -LiteralPath $ProjectsRoot -Recurse -Filter "$id.jsonl" -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
        }
        if (-not $jf) { $missing += $id; continue }
        $meta = Get-ClaudeSessionMeta -Path $jf.FullName
        if (-not $meta.Cwd) { $missing += $id; continue }
        if (-not $IncludeMissing -and -not (Test-Path -LiteralPath $meta.Cwd)) {
            Write-Host (C '1;33' "  Skipping $id — its working directory no longer exists: $($meta.Cwd)")
            continue
        }
        $found += $meta
    }
    if ($missing.Count -gt 0) {
        # Fail LOUD. Silently resuming a subset of what was asked for is how work
        # goes missing without anyone noticing.
        Write-Host ''
        Write-Host (C '1;31' '  Session id(s) not found:')
        foreach ($m in $missing) { Write-Host ('    ' + (C '1;31' $m)) }
        Write-Host ''
        exit 3
    }
    if ($found.Count -eq 0) {
        Write-Host '  Nothing to resume.' -ForegroundColor Yellow
        exit 0
    }
    $selectedById = @($found)
}

if ($selectedById) {
    # Ids already resolved above — the whole candidate scan below is unnecessary.
    $sessions = $selectedById
}
else {

# Only real top-level conversations are resumable: their journal is named with a
# UUID. Sub-agent sidechains (agent-*.jsonl) and workflow journals (journal.jsonl)
# are not. They must be excluded BEFORE the -Scan truncation, not after: agents
# rewrite them constantly, so by write-time they dominate the head of the list and
# would otherwise consume the entire scan window (measured: 103 of the 120 most
# recent journals here), starving out the real sessions.
$uuid = $uuidRe

$files = Get-ChildItem -LiteralPath $ProjectsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -match $uuid } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $Scan

if (-not $files) {
    Write-Host "No Claude Code sessions found under $ProjectsRoot" -ForegroundColor Yellow
    exit 0
}

$sessions = foreach ($f in $files) { Get-ClaudeSessionMeta -Path $f.FullName }

# Filters
$sessions = $sessions | Where-Object { $_.Cwd }
if (-not $IncludeMissing) {
    $sessions = $sessions | Where-Object { Test-Path -LiteralPath $_.Cwd }
}
if ($ExcludeSession) {
    $sessions = $sessions | Where-Object { $_.Id -ne $ExcludeSession }
}
if ($Filter) {
    $sessions = $sessions | Where-Object {
        "$($_.Title) $($_.Cwd) $($_.LastPrompt)" -match [regex]::Escape($Filter)
    }
}
if ($LookbackHours -gt 0) {
    $cut = (Get-Date).AddHours(-$LookbackHours)
    $sessions = $sessions | Where-Object { $_.When -and $_.When -ge $cut }
}

$sessions = $sessions | Sort-Object When -Descending

if ($PerDir) {
    $sessions = $sessions | Group-Object Cwd | ForEach-Object {
        $_.Group | Sort-Object When -Descending | Select-Object -First 1
    } | Sort-Object When -Descending
}

}  # end: candidate scan (skipped entirely when -SelectId resolved ids directly)

# -Top bounds the browsable list; it must never silently drop a session the caller
# named explicitly by id.
if (-not $selectedById) {
    $sessions = @($sessions | Select-Object -First $Top)
}

if ($sessions.Count -eq 0) {
    Write-Host "No matching sessions to resume." -ForegroundColor Yellow
    exit 0
}

# --- JSON mode (for /resume-all and tooling) --------------------------------
if ($Json) {
    $i = 0
    $sessions | ForEach-Object {
        $i++
        [pscustomobject]@{
            index      = $i
            id         = $_.Id
            title      = $_.Title
            cwd        = $_.Cwd
            branch     = $_.Branch
            lastPrompt = $_.LastPrompt
            when       = if ($_.When) { $_.When.ToString('o') } else { $null }
            age        = (Format-Age $_.When).Trim()
        }
    } | ConvertTo-Json -Depth 4
    exit 0
}

# --- Render table -----------------------------------------------------------
function Show-Table {
    Write-Host ''
    Write-Host (C '1;36' '  Claude Code — resumable sessions')
    Write-Host (C '90' ('  ' + ('-' * 70)))
    $idx = 0
    foreach ($s in $sessions) {
        $idx++
        $n      = '{0,2}' -f $idx
        $age    = '{0,-9}' -f (Format-Age $s.When)
        $title  = $s.Title
        if ($title.Length -gt 34) { $title = $title.Substring(0, 33) + '…' }
        $title  = '{0,-34}' -f $title
        $branch = if ($s.Branch) { " ($($s.Branch))" } else { '' }
        Write-Host ("  " + (C '1;33' $n) + "  " + (C '90' $age) + "  " + (C '1;37' $title) + (C '36' $branch))
        Write-Host ("        " + (C '90' $s.Cwd))
        if ($s.LastPrompt) {
            $lp = ($s.LastPrompt -replace '\s+', ' ').Trim()
            if ($lp.Length -gt 64) { $lp = $lp.Substring(0, 63) + '…' }
            Write-Host ("        " + (C '32' ('> ' + $lp)))
        }
    }
    Write-Host (C '90' ('  ' + ('-' * 70)))
}

# --- Decide selection -------------------------------------------------------
$chosenIdx = @()

# -SelectId already resolved its sessions (by journal filename, before the scan) —
# it is the SAFE, race-free way to choose, and the one tooling must use. Positional
# -Select is a trap for any caller that lists in one process and launches in another:
# sessions sort by last-active time and journals are rewritten CONTINUOUSLY (by other
# running sessions, and by the agent driving this script), so the list can REORDER
# between the two calls and index N silently becomes a different session. Observed
# live, two invocations seconds apart. Ids are stable; positions are not.
if ($selectedById) {
    $chosen = $selectedById
}
elseif ($All) {
    $chosenIdx = 1..$sessions.Count
    Show-Table
} elseif ($Select) {
    $chosenIdx = Expand-Selection -Spec $Select -Count $sessions.Count
    Show-Table
} else {
    Show-Table
    Write-Host ''
    Write-Host (C '90' "  Pick sessions to resume: e.g. 1,3,5-7  •  'a' = all  •  Enter = cancel")
    $answer = Read-Host '  resume'
    if ([string]::IsNullOrWhiteSpace($answer)) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        exit 0
    }
    $chosenIdx = Expand-Selection -Spec $answer -Count $sessions.Count
}

if (-not $SelectId) {
    if (-not $chosenIdx -or $chosenIdx.Count -eq 0) {
        Write-Host '  Nothing selected.' -ForegroundColor Yellow
        exit 0
    }
    $chosen = @($chosenIdx | ForEach-Object { $sessions[$_ - 1] })
}

# --- Launch -----------------------------------------------------------------
# Backends, in preference order. PowerShell 7 is cross-platform, and so is Claude
# Code, so the resumer must be too — the only OS-specific part is HOW we spawn a
# terminal per session:
#   tmux  — any OS. The only backend that survives an SSH disconnect, so it is the
#           right one when you're driving this from a phone/remote shell. Forced
#           with -Tmux; auto-selected when there is no GUI terminal available.
#   wt    — Windows Terminal tabs (Windows default when present).
#   macOS — Terminal.app tabs via osascript.
#   else  — print the commands rather than pretend we launched something.
# NOTE: not $tmux — PowerShell variable names are CASE-INSENSITIVE, so `$tmux`
# would silently clobber the -Tmux switch parameter and make it always-truthy.
$wt = if ($IsWindows) { Get-Command wt -CommandType Application -ErrorAction SilentlyContinue } else { $null }

# Probe for tmux ONLY when it could actually be used. An unqualified
# `Get-Command tmux` for a command that does NOT exist makes PowerShell walk every
# PATH entry against every PATHEXT extension; on a box with a slow/dead PATH entry
# that took >90 SECONDS and looked exactly like a hang. -CommandType Application
# skips the cmdlet/function/alias lookups too.
$tmuxCmd = $null
if ($Tmux -or -not $IsWindows) {
    $tmuxCmd = Get-Command tmux -CommandType Application -ErrorAction SilentlyContinue
}

if ($DryRun) {
    # stdout (Write-Output), NOT Write-Host: a dry run is data — the caller should
    # be able to pipe/redirect/diff it, and CI needs to assert on it.
    Write-Output "DRY RUN — would resume $($chosen.Count) session(s):"
    foreach ($s in $chosen) {
        Write-Output "  [$($s.Id)] $($s.Title)"
        Write-Output "      cd $($s.Cwd) && claude --resume $($s.Id)"
    }
    exit 0
}

function New-TabArgs {
    param($Session, [bool]$Lead)
    $a = [System.Collections.Generic.List[string]]::new()
    if (-not $Lead) { $a.Add(';') }
    $a.Add('new-tab')
    $a.Add('-d');     $a.Add($Session.Cwd)
    $a.Add('--title'); $a.Add($Session.Title)
    $a.Add('pwsh'); $a.Add('-NoExit'); $a.Add('-Command'); $a.Add("claude --resume $($Session.Id)")
    $a
}

function Get-TmuxWindowName {
    # tmux window names: no dots/colons (they are target separators), keep it short.
    param([string]$Title)
    $n = ($Title -replace '[^\w\- ]', '' -replace '\s+', '-').Trim('-')
    if (-not $n) { $n = 'claude' }
    if ($n.Length -gt 24) { $n = $n.Substring(0, 24) }
    $n
}

# Choose tmux when asked, or when there is simply no GUI terminal to spawn.
$useTmux = $tmuxCmd -and ($Tmux -or (-not $wt -and -not $IsMacOS))

if ($useTmux) {
    # Reuse an existing session of this name if there is one, otherwise the first
    # chosen session creates it and the rest become windows inside it.
    & $tmuxCmd.Source has-session -t $TmuxSession 2>$null | Out-Null
    $sessionExists = ($LASTEXITCODE -eq 0)

    foreach ($s in $chosen) {
        $name = Get-TmuxWindowName $s.Title
        $cmd  = "claude --resume $($s.Id)"
        if (-not $sessionExists) {
            & $tmuxCmd.Source new-session -d -s $TmuxSession -n $name -c $s.Cwd $cmd
            $sessionExists = $true
        } else {
            & $tmuxCmd.Source new-window -t $TmuxSession -n $name -c $s.Cwd $cmd
        }
    }
    Write-Host ''
    Write-Host (C '1;32' "  Resumed $($chosen.Count) session(s) in tmux session '$TmuxSession':")
    foreach ($s in $chosen) { Write-Host ("    • " + (C '1;37' $s.Title) + (C '90' "  ($($s.Cwd))")) }
    Write-Host ''
    if ($env:TMUX) {
        Write-Host (C '90' "  Already inside tmux — switch windows with Ctrl-b n / Ctrl-b w")
    } else {
        Write-Host (C '1;36' "  Attach with:  tmux attach -t $TmuxSession")
    }
    Write-Host ''
    exit 0
}

if ($IsMacOS -and -not $wt) {
    foreach ($s in $chosen) {
        # Escape for AppleScript's double-quoted string literals.
        $esc = ("cd " + $s.Cwd + " && claude --resume " + $s.Id) -replace '\\', '\\\\' -replace '"', '\"'
        & osascript -e "tell application `"Terminal`" to do script `"$esc`"" | Out-Null
    }
    Write-Host ''
    Write-Host (C '1;32' "  Resuming $($chosen.Count) session(s) in Terminal.app:")
    foreach ($s in $chosen) { Write-Host ("    • " + (C '1;37' $s.Title) + (C '90' "  ($($s.Cwd))")) }
    Write-Host ''
    exit 0
}

if (-not $wt) {
    # No GUI terminal and no tmux: print the commands instead of silently doing
    # nothing (or spawning windows that cannot exist on a headless box).
    Write-Host ''
    Write-Host (C '1;33' '  No supported terminal found (install tmux, or Windows Terminal on Windows).')
    Write-Host (C '90'   '  Run these yourself:')
    foreach ($s in $chosen) {
        Write-Host ''
        Write-Host ("    " + (C '1;37' $s.Title))
        Write-Host ("    cd " + $s.Cwd)
        Write-Host ("    claude --resume " + $s.Id)
    }
    Write-Host ''
    exit 0
}

if ($SeparateWindows) {
    foreach ($s in $chosen) {
        $args = @('-w', 'new') + (New-TabArgs -Session $s -Lead $true)
        Start-Process $wt.Source -ArgumentList $args
    }
}
else {
    # All tabs in one new window.
    $args = [System.Collections.Generic.List[string]]::new()
    $lead = $true
    foreach ($s in $chosen) {
        (New-TabArgs -Session $s -Lead $lead) | ForEach-Object { $args.Add($_) }
        $lead = $false
    }
    Start-Process $wt.Source -ArgumentList $args
}

Write-Host ''
Write-Host (C '1;32' "  Resuming $($chosen.Count) session(s):")
foreach ($s in $chosen) { Write-Host ("    • " + (C '1;37' $s.Title) + (C '90' "  ($($s.Cwd))")) }
Write-Host ''
