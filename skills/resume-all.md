---
description: Reopen your killed Claude Code sessions — pick from every project, resume as terminal tabs or tmux windows
argument-hint: "[all | 1,3,5 | <filter text>]  (empty = pick interactively)"
allowed-tools: Bash(pwsh:*)
---

You are helping the user resume their previously-killed Claude Code sessions.

The engine is `scripts/Resume-ClaudeSessions.ps1` from the `aither-skills` repo.
Replace `<ENGINE>` below with wherever you saved it. It is read-only against the
session history — it never mutates the journals.

Arguments the user passed: `$ARGUMENTS`

Do this:

1. List resumable sessions as JSON:

   ```
   pwsh -NoProfile -File "<ENGINE>" -Json -Scan 200 -Top 40
   ```

   A directory usually holds MANY sessions and the user typically wants a specific
   one, so list them all rather than collapsing per directory. Add `-PerDir` only
   if they explicitly ask for "one per workspace" / "one per project".

2. Interpret `$ARGUMENTS`:
   - **empty** → present the JSON as a numbered list **grouped by working
     directory** (title · age · last prompt under each cwd heading), then ask which
     numbers to resume. Wait for their answer.
   - **`all`** → resume every listed session.

   Liveness check first, whatever the argument: a session whose `when` is within
   the last ~3 minutes is probably LIVE in another window right now — its journal
   is still being written. Resuming it spawns a DUPLICATE. Mark those
   `⚡ likely live — skipped`, exclude them from `all`, and only resume one if the
   user names it explicitly.
   - **a list like `1,3,5-7`** → resume those indices.
   - **anything else** → treat it as a `-Filter` substring; re-run step 1 adding
     `-Filter "<text>"`, then confirm the matches with the user.

3. Reopen the chosen sessions — **always by session id, never by list position**:

   ```
   pwsh -NoProfile -File "<ENGINE>" -SelectId "<id1>,<id2>"
   ```

   Map the user's chosen numbers back to the `id` fields from the step-1 JSON, and
   pass those. Do NOT pass `-Select <numbers>` here.

   ⚠️ Why: sessions sort by last-active time, and Claude Code rewrites session
   journals continuously — including the session you are running in. The list can
   therefore **reorder between your list call and your launch call**, so position 1
   in step 1 may be a different session by step 3. Ids are stable; positions are not.
   `-SelectId` also fails loudly (exit 3) if an id is no longer a candidate, instead
   of silently resuming a subset.

   `-DryRun` prints the resolved sessions to stdout without launching anything.

   Backends are picked automatically: Windows Terminal tabs on Windows, tmux
   windows if tmux is present, Terminal.app on macOS. Add `-Tmux` to force tmux —
   **that's the one to use over SSH**, since tmux windows survive a disconnect.
   Add `-SeparateWindows` for separate windows instead of tabs.

   Resumed tabs come up in COLOR even when you launch this from inside a Claude
   Code session. That is not free: Claude Code exports `NO_COLOR=1` to its
   subprocesses so tool output comes back clean, and the terminal spawned by this
   engine is one of those subprocesses — so the new window, every shell in it, and
   every `claude` inside those shells would inherit `NO_COLOR=1` and render
   monochrome. The engine scrubs it per tab (`Remove-Item Env:NO_COLOR` on the wt
   path, `unset NO_COLOR` on tmux). Keep that scrub if you edit the launch command.
   It must DELETE the variable, not blank it — the consumer tests
   `!("NO_COLOR" in process.env)`, i.e. presence, so `NO_COLOR=""` still suppresses
   colour. Worst on tmux: a server started from a Claude session keeps that
   environment for every window created later.

4. Report which sessions were reopened (titles + directories). If tmux was used,
   tell the user the attach command the engine printed.

Never resume a session whose working directory no longer exists (the engine
already skips those).
