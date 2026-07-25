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
       bounded RAW tail read + last-match regex extraction is accurate and ~ms
       even on 50MB journals. The previous implementation (Get-Content -Tail 120
       piped line-by-line through ConvertFrom-Json) cost ~70ms/file — ×120 files
       that was the entire "why does listing take a minute" bug. #>
    param([string]$Path)

    $id = [IO.Path]::GetFileNameWithoutExtension($Path)

    # Raw tail read. Journals are append-mostly JSONL and the metadata we want is
    # rewritten near the end; 256KB covers it in practice. A single giant line
    # (multi-MB pasted tool result) can push it further back, so retry once with
    # a 4MB window if no cwd surfaced. FileShare includes Delete so a journal
    # being rotated/removed mid-read degrades to "skip", not a crash.
    $readTail = {
        param([string]$p, [long]$take)
        try {
            $fs = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                  ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $n = [int][Math]::Min($take, $fs.Length)
                if ($n -le 0) { return '' }
                $null = $fs.Seek(-$n, [IO.SeekOrigin]::End)
                $buf  = [byte[]]::new($n)
                $read = $fs.Read($buf, 0, $n)
                [Text.Encoding]::UTF8.GetString($buf, 0, $read)
            } finally { $fs.Dispose() }
        } catch { '' }
    }

    # Walk the tail lines NEWEST-FIRST and take each field from the first line
    # whose TOP-LEVEL property carries it. The Contains precheck keeps this cheap
    # (a line is JSON-parsed only if it can possibly hold a wanted field, and each
    # field stops looking once found); parsing the full line — instead of a bare
    # regex over the raw text — is what makes it correct: an unescaped nested key
    # inside a structured toolUseResult (e.g. a nested "timestamp") can never
    # shadow the real top-level value. Values inside message strings are
    # backslash-escaped (\"key\":) in the raw bytes, so the '"key":' needle
    # cannot false-positive on content either.
    $extract = {
        param([string]$text)
        $found = @{}
        $want  = [System.Collections.Generic.List[string]]@('aiTitle', 'lastPrompt', 'cwd', 'timestamp', 'gitBranch')
        $lines = $text.Split("`n")
        for ($i = $lines.Count - 1; $i -ge 0 -and $want.Count -gt 0; $i--) {
            $line = $lines[$i]
            $mayHold = $false
            foreach ($k in $want) {
                if ($line.Contains('"' + $k + '":')) { $mayHold = $true; break }
            }
            if (-not $mayHold) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }  # partial first line etc.
            foreach ($k in @($want)) {
                $v = $o.$k
                if ($v -is [string] -and $v) {
                    $found[$k] = $v
                    $null = $want.Remove($k)
                }
            }
        }
        $found
    }

    $text = & $readTail $Path 262144
    $f    = & $extract $text
    if (-not $f['cwd']) {
        $text = & $readTail $Path 4194304
        $f    = & $extract $text
    }

    $title      = $f['aiTitle']
    $lastPrompt = $f['lastPrompt']
    $cwd        = $f['cwd']
    $ts         = $f['timestamp']
    $branch     = $f['gitBranch']

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
    if (-not $when) {
        # No parseable timestamp in the tail window — the journal's mtime is the
        # honest approximation, and far better than sorting the session as "? age".
        try { $when = [IO.File]::GetLastWriteTime($Path) } catch { }
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

# Parallel parse: each file is an independent tail-read, and even at ~ms each,
# $Scan of them serially still adds up on a cold/AV-scanned disk. Order doesn't
# matter — everything is re-sorted by When below.
$metaDef = ${function:Get-ClaudeSessionMeta}.ToString()
$sessions = @($files | ForEach-Object -Parallel {
    ${function:Get-ClaudeSessionMeta} = $using:metaDef
    Get-ClaudeSessionMeta -Path $_.FullName
} -ThrottleLimit 8)

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

# Resolve pwsh to an ABSOLUTE path once. Wt's new-tab resolves a bare `pwsh`
# against the spawned tab's PATH, which is not guaranteed to carry pwsh; a full
# path removes that failure mode entirely.
$script:PwshPath = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue).Source
if (-not $script:PwshPath) { $script:PwshPath = 'pwsh' }

function New-TabArgs {
    param($Session, [bool]$Lead)
    $a = [System.Collections.Generic.List[string]]::new()
    if (-not $Lead) { $a.Add(';') }
    $a.Add('new-tab')
    $a.Add('-d');     $a.Add($Session.Cwd)
    $a.Add('--title'); $a.Add($Session.Title)
    # Scrub inherited colour-suppression before starting claude. When this script is
    # run FROM a Claude Code session, that session exports NO_COLOR=1 (and renders
    # PlainText) so its own tool output comes back clean. wt is spawned as a child of
    # that process, so the new window — and every pwsh tab in it, and every claude
    # inside those tabs — inherits NO_COLOR=1 and resumes fully monochrome. Verified
    # live 2026-07-20: probe tab reported NO_COLOR=[1], OutputRendering=PlainText.
    # Launching from a normal terminal was never affected, which is why this looked
    # like a Windows Terminal/profile problem and is not one.
    # The payload MUST be passed as -EncodedCommand, not -Command: wt splits its own
    # command line on semicolons EVEN INSIDE QUOTED ARGUMENTS (they'd need \; escaping).
    # With -Command, wt chopped this string at each ';' — the tab ran only the
    # Remove-Item prefix and the orphaned " claude --resume <id>" tail became a bogus
    # separate launch that died with 0x80070002 "file not found" for EVERY session
    # (broke all resumes 2026-07-20 → 2026-07-22). Base64 has no ';', so it's immune.
    # Also scrub the parent Claude session's identity vars — when this script runs FROM
    # a Claude Code session, the tabs inherit CLAUDE_CODE_SESSION_ID etc. of the CALLER,
    # polluting the resumed instance.
    $payload = "Remove-Item Env:NO_COLOR, Env:CLAUDECODE, Env:CLAUDE_CODE_SESSION_ID, " +
               "Env:CLAUDE_CODE_CHILD_SESSION, Env:CLAUDE_CODE_ENTRYPOINT, Env:CLAUDE_PID " +
               "-ErrorAction SilentlyContinue; `$PSStyle.OutputRendering='Ansi'; " +
               "claude --resume $($Session.Id)"
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($payload))
    $a.Add($script:PwshPath); $a.Add('-NoExit'); $a.Add('-EncodedCommand'); $a.Add($b64)
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
        # Same inherited-NO_COLOR scrub as the wt path (see New-TabArgs). Worse here:
        # a tmux SERVER started from a Claude Code session keeps that environment for
        # every window created later, so the monochrome outlives the launching session.
        $cmd  = "unset NO_COLOR; claude --resume $($s.Id)"
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
        # Escape for AppleScript's double-quoted string literals. The leading
        # `unset NO_COLOR` is the same scrub as the wt/tmux paths (see New-TabArgs):
        # launched from a Claude Code session, this process carries NO_COLOR=1 and
        # Terminal.app would inherit it, resuming every tab monochrome. It contains
        # no backslash or quote, so it does not interact with the escaping below.
        # The cwd is single-quoted for the SHELL: unquoted, a path containing a
        # space ("/Users/x/my proj") splits into two words and the cd fails, so the
        # tab opens in the wrong directory and the resume dies. The wt/tmux paths
        # never had this — they pass the cwd as its own argv element. Single quotes
        # also survive the AppleScript escaping below, which only touches \ and ".
        $shell = "unset NO_COLOR; cd '" + $s.Cwd + "' && claude --resume " + $s.Id
        $esc = $shell -replace '\\', '\\\\' -replace '"', '\"'
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

# Launch via the call operator, NOT Start-Process -ArgumentList. Start-Process
# flattens an argument array into a single string WITHOUT quoting elements that
# contain spaces, so a multi-word --title (any AI-generated session title with a
# space) leaks its trailing words into the command position; wt then tries to
# launch the leftover word as an executable and dies with
# `0x80070002 file not found`. Observed: every space-containing title failed,
# every no-space slug title succeeded. PowerShell 7's native invocation (`&`
# with a splatted array) builds a correctly-quoted argv, so wt sees --title's
# value as a single token. wt is a launcher that returns immediately, so this
# does not block on the spawned tabs.
if ($SeparateWindows) {
    foreach ($s in $chosen) {
        # $wtArgs, not $args — $args is PowerShell's fixed-size automatic variable
        $wtArgs = @('-w', 'new') + (New-TabArgs -Session $s -Lead $true)
        & $wt.Source @wtArgs
    }
}
else {
    # All tabs in one new window.
    $wtArgs = [System.Collections.Generic.List[string]]::new()
    $lead = $true
    foreach ($s in $chosen) {
        foreach ($a in (New-TabArgs -Session $s -Lead $lead)) { $wtArgs.Add($a) }
        $lead = $false
    }
    & $wt.Source @wtArgs
}

Write-Host ''
Write-Host (C '1;32' "  Resuming $($chosen.Count) session(s):")
foreach ($s in $chosen) { Write-Host ("    • " + (C '1;37' $s.Title) + (C '90' "  ($($s.Cwd))")) }
Write-Host ''
