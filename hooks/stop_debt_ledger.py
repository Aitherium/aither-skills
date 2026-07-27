#!/usr/bin/env python3
"""Stop hook — the tech-debt ledger gate (see skills/debt-ledger.md).

Blocks a turn that changed code without touching the ledger, with one explicit
escape hatch: saying "no new debt: <why>" passes.

That escape hatch is not a weakness, it is the whole design. A gate with no
legitimate way through gets disabled inside a week, and a disabled gate guards
nothing. What this buys is that skipping the check becomes a *stated* act
instead of silence.

WIRE IT UP        see hooks/README.md
CONFIGURE         DEBT_LEDGER         ledger filename (default TECH_DEBT.md)
                  DEBT_LEDGER_IGNORE  comma-separated glob(s) of paths whose
                                      edits do not count as a code change
                                      (e.g. "docs/*,*.md")
SELF-TEST         python3 hooks/test_hooks.py
"""

from __future__ import annotations

import fnmatch
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hook_common import (  # noqa: E402
    assistant_text,
    block,
    matches,
    run_hook,
    shell_commands,
    written_paths,
)

# "checked, no new debt: the change is a pure rename" and friends.
EXEMPTION = r"no\s+new\s+(tech[\s-]*)?debt"


def _ledger_name() -> str:
    return os.environ.get("DEBT_LEDGER", "TECH_DEBT.md").strip() or "TECH_DEBT.md"


def _ignored(path: str) -> bool:
    raw = os.environ.get("DEBT_LEDGER_IGNORE", "")
    patterns = [p.strip() for p in raw.split(",") if p.strip()]
    if not patterns:
        return False
    norm = path.replace("\\", "/")
    base = norm.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatch(norm, p) or fnmatch.fnmatch(base, p) for p in patterns)


def _touches_ledger(path: str, ledger: str) -> bool:
    return path.replace("\\", "/").rsplit("/", 1)[-1].lower() == ledger.lower()


def decide(payload: dict[str, Any], turn: list[dict[str, Any]]) -> None:
    ledger = _ledger_name()
    paths = written_paths(turn)

    # Nothing was written -> nothing to record.
    if not paths:
        return

    # The ledger itself was edited -> the check happened.
    if any(_touches_ledger(p, ledger) for p in paths):
        return

    # A shell command that writes the ledger counts too (heredoc, append, an
    # editor invocation) — only the ledger being untouched is worth blocking on.
    if any(ledger.lower() in cmd.lower() for cmd in shell_commands(turn)):
        return

    code_paths = [p for p in paths if not _ignored(p)]
    if not code_paths:
        return

    # The stated exemption.
    if matches(EXEMPTION, assistant_text(turn)):
        return

    changed = ", ".join(sorted({p.replace("\\", "/") for p in code_paths})[:6])
    block(
        f"Tech-debt check: this turn changed code ({changed}) and did not touch {ledger}.\n"
        "\n"
        "Answer the one question the ledger exists for: what did you just leave worse than "
        "it should be, or notice was already broken and not fix? A shortcut, a skipped edge "
        "case, a TODO, a swallowed exception, a hardcoded value, a disabled test, or a bug "
        "you found and did not fix.\n"
        "\n"
        f"  * Something to record -> append a row to {ledger} (id, area, the mechanism in "
        "full, file(s), today's date, status), then stop.\n"
        "  * Genuinely nothing -> say so in those words: \"checked, no new debt: <one line "
        "why>\", then stop. Silence is not the same answer.\n"
        "\n"
        "Do not re-list debt the ledger already carries."
    )


if __name__ == "__main__":
    run_hook(decide)
