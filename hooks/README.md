# hooks — the gates that make the standards real

Three skills in this pack describe a discipline that only works if something enforces it:

| skill | standard | hook |
|---|---|---|
| [`prove-it-live`](../skills/prove-it-live.md) | green / 200 / deployed ≠ done | `stop_live_proof.py` |
| [`debt-ledger`](../skills/debt-ledger.md) | debt found is debt recorded, same turn | `stop_debt_ledger.py` |
| [`automate-the-manual`](../skills/automate-the-manual.md) | work done by hand twice is a script that was never written | `stop_automation_gap.py` |

All are **Stop hooks**: they run when the agent tries to end a turn, and can refuse.
Standard library Python only (3.8+), no install step, no network.

They are gates for the same reason: each standard is obvious, each is agreed with by
everyone, and each is enforced by nothing except a human remembering to care at the
one moment they are busiest.

---

## Install

```bash
mkdir -p .claude/hooks
cp hooks/hook_common.py hooks/stop_debt_ledger.py hooks/stop_live_proof.py \
   hooks/stop_automation_gap.py .claude/hooks/
python3 hooks/test_hooks.py                       # prove they work before wiring them
```

Then add this to `.claude/settings.json` (merge with what is already there — do not
replace the file):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop_debt_ledger.py\"" },
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop_live_proof.py\"" },
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop_automation_gap.py\"" }
        ]
      }
    ]
  }
}
```

**Windows:** `python3` frequently is not on PATH — use `python`, or an absolute
interpreter path. If a hook cannot start, the turn simply ends as normal; a gate that
kills sessions gets deleted, so failure is silent by design. Confirm it is actually
wired by running the self-test and by watching one turn get blocked.

Restart the agent — hooks are read at startup.

---

## What each one does

### `stop_debt_ledger.py`

| turn | decision |
|---|---|
| wrote a file, ledger untouched | **block** |
| wrote a file, also wrote `TECH_DEBT.md` | allow |
| wrote a file, said "no new debt: `<why>`" | allow |
| wrote nothing | allow |
| already continuing from a block | allow |

### `stop_live_proof.py`

| turn | decision |
|---|---|
| wrote a file, ends claiming done/fixed/deployed/working, nothing exercised it | **block** |
| same, but a test / lint / build / probe ran | allow |
| same, but said "unverified because `<reason>`" | allow |
| no completion claim in the closing message | allow |
| wrote nothing | allow |
| already continuing from a block | allow |

### `stop_automation_gap.py`

| turn | decision |
|---|---|
| ran the same command shape 3+ times, no decision recorded | **block** |
| typed a 3+ step mutating chain by hand, no decision recorded | **block** |
| ran a shape already seen in another session, no decision recorded | **block** |
| every shape has an `automated` or `wontfix` row in the backlog | allow |
| only reads, only one-off commands, or only existing scripts | allow |
| ran no commands at all | allow |
| already raised 3 times for this same batch | allow, with a note on stderr |

Reads (`ls`, `docker ps`, `git log`) can only be caught by the cross-session rule, and
inline one-off scripts (`python -c`, heredocs) are excluded from every rule and counted
instead — both because a rule that floods gets switched off. It runs the same detector
as the skill's `--report`, so the gate and the report cannot disagree.

Only turns that **changed a file** are gated by the first two hooks, and only the
**closing message** counts as the verdict. Both narrowings exist to keep the gates off
ordinary conversation — a hook that fires on everything is a hook that gets switched
off. The automation gate instead gates turns that **ran commands**, for the same
reason: a turn that ran nothing cannot have done anything by hand.

---

## The escape hatches are load-bearing

`"no new debt: <why>"`, `"unverified because <reason>"` and a `status: wontfix` row
with a reason all pass, on purpose.

A gate with no legitimate way through gets disabled within a week, and a disabled gate
guards nothing. What these buy is not enforcement of the outcome — it is that skipping
the check becomes a **stated** act instead of silence. "No new debt" is a valid answer;
not answering is not.

---

## Configuration

| variable | hook | meaning |
|---|---|---|
| `DEBT_LEDGER` | debt | ledger filename (default `TECH_DEBT.md`) |
| `DEBT_LEDGER_IGNORE` | debt | comma-separated globs whose edits are not a code change, e.g. `docs/*,*.md` |
| `LIVE_PROOF_EVIDENCE` | live | extra regex OR-ed into the evidence patterns, e.g. `bazel\s+test` |
| `AUTOMATION_BACKLOG` | automation | decision file (default `.claude/automation-backlog.yaml`) |
| `AUTOMATION_GAP_REPEAT` | automation | AT001 threshold — same shape N times in one turn (3) |
| `AUTOMATION_GAP_CHAIN` | automation | AT002 threshold — steps in a hand-typed chain (3) |
| `AUTOMATION_GAP_SESSIONS` | automation | AT003 threshold — distinct sessions (2) |
| `AUTOMATION_GAP_MAX_BLOCKS` | automation | raises per batch before it gives up (3) |
| `AUTOMATION_GAP_OFF` | automation | set to disable; it says so on stderr rather than going quiet |

Set them in the hook command itself if your agent does not pass the environment through:

```json
{ "type": "command", "command": "DEBT_LEDGER=DEBT.md python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop_debt_ledger.py\"" }
```

---

## Self-test

```bash
python3 hooks/test_hooks.py       # every case, all three hooks
python3 hooks/test_hooks.py -v    # name each as it passes
```

Every case spawns the real script with a real transcript on disk and asserts on the JSON
it writes back, because a hook that imports cleanly can still be a no-op. The suite is
mutation-verified: breaking write-detection turns all five block-asserting cases red, and
disabling evidence-detection turns three allow-asserting cases red. If you change a
pattern, run it — that is the only thing standing between "the gate is tuned" and "the
gate is inert".

---

## Porting to another agent

The logic is agent-agnostic; only the transport is Claude-specific:

- **in** — one JSON object on stdin carrying `transcript_path` and `stop_hook_active`
- **out** — `{}` to end the turn, `{"decision":"block","reason":"..."}` to keep going
- **transcript** — JSONL, one entry per line, assistant entries carrying `tool_use`
  blocks with `name` and `input`

If your agent exposes a different end-of-turn hook, replace `read_payload()` and
`block()` in `hook_common.py` and everything above them still applies. If it exposes no
end-of-turn hook at all, the standards still stand — they are just back to being
enforced by a human remembering to care, which is the situation these files exist to
improve on.

---

## Honest limits

- **Evidence detection is a heuristic.** It reads command lines, so it is satisfied by
  running something irrelevant. It raises the floor; it proves nothing by itself.
- **The debt gate is blunt.** "Code changed, ledger didn't" fires on genuinely debt-free
  changes too. That is what the stated exemption is for.
- **The automation gate counts, it does not judge.** Three rules over command lines
  cannot know which work was worth automating — only that it was done more than once.
  Frequency is the only signal it has; *cost* is not, so the expensive thing you did
  carefully once is invisible to it. What it buys is that walking away from a repeated
  procedure becomes a stated decision rather than the default one.
- **No gate reads your diff.** They see which tools ran and what the agent wrote — not
  whether the fix is correct. No hook can do that.
