# hooks — the two gates that make the standards real

Two skills in this pack describe a discipline that only works if something enforces it:

| skill | standard | hook |
|---|---|---|
| [`prove-it-live`](../skills/prove-it-live.md) | green / 200 / deployed ≠ done | `stop_live_proof.py` |
| [`debt-ledger`](../skills/debt-ledger.md) | debt found is debt recorded, same turn | `stop_debt_ledger.py` |

Both are **Stop hooks**: they run when the agent tries to end a turn, and can refuse.
Standard library Python only (3.8+), no install step, no network.

---

## Install

```bash
mkdir -p .claude/hooks
cp hooks/hook_common.py hooks/stop_debt_ledger.py hooks/stop_live_proof.py .claude/hooks/
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
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop_live_proof.py\"" }
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

Only turns that **changed a file** are gated, and only the **closing message** counts as
the verdict. Both narrowings exist to keep the gates off ordinary conversation — a hook
that fires on everything is a hook that gets switched off.

---

## The escape hatches are load-bearing

`"no new debt: <why>"` and `"unverified because <reason>"` both pass, on purpose.

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

Set them in the hook command itself if your agent does not pass the environment through:

```json
{ "type": "command", "command": "DEBT_LEDGER=DEBT.md python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop_debt_ledger.py\"" }
```

---

## Self-test

```bash
python3 hooks/test_hooks.py       # 21 cases
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
- **Neither gate reads your diff.** They see which tools ran and what the agent wrote —
  not whether the fix is correct. No hook can do that.
