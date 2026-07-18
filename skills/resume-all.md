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

4. Report which sessions were reopened (titles + directories). If tmux was used,
   tell the user the attach command the engine printed.

Never resume a session whose working directory no longer exists (the engine
already skips those).
