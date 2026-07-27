#!/usr/bin/env python3
"""Stop hook — the live-proof gate (see skills/prove-it-live.md).

Blocks a turn that changed something and then claimed it was done, fixed,
deployed or working, when nothing in the turn actually exercised it.

    claim + no evidence            -> block
    claim + a command that ran it  -> allow
    "unverified because X"         -> allow (the escape hatch)
    no claim, or nothing changed   -> allow

WHAT THIS IS AND IS NOT
    It is a floor. Detecting "evidence" by looking at command lines is a
    heuristic and is satisfiable by running something irrelevant — it cannot
    prove anything by itself. What it does is make skipping verification a
    deliberate act rather than an accidental one, which is the actual win.
    The skill body is the standard; this only stops the standard being
    forgotten silently.

WIRE IT UP        see hooks/README.md
CONFIGURE         LIVE_PROOF_EVIDENCE  extra regex OR-ed into the evidence
                                       patterns (e.g. "just test|bazel test")
SELF-TEST         python3 hooks/test_hooks.py
"""

from __future__ import annotations

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

# Completion language. Only consulted for turns that actually changed a file,
# which is what keeps this off ordinary conversational "done".
CLAIM = (
    r"\b(done|fixed|fixes\s+it|deployed|resolved|complete|completed|"
    r"works|working\s+now|it'?s\s+live|now\s+live|verified|passing)\b"
)

# "unverified", "not verified", "cannot verify live", "no live check".
EXEMPTION = (
    r"\bunverified\b|\bnot\s+(yet\s+)?verified\b|\bcan(?:no|')t\s+(be\s+)?verif|"
    r"\bunable\s+to\s+verif|\bno\s+live\s+(check|proof|test)\b"
)

# A command that could actually have failed. Ordered by strength of proof, but
# any single match is enough — see the honest limit above.
EVIDENCE = (
    # tests
    r"pytest|py\.test|unittest|npm\s+(run\s+)?test|yarn\s+test|pnpm\s+test|jest|vitest|"
    r"mocha|go\s+test|cargo\s+test|dotnet\s+test|gradle\s+test|mvn\s+test|rspec|phpunit|"
    r"Invoke-Pester|\bpester\b|\bctest\b|\bbats\b|\btox\b|\bnox\b"
    # lint / types
    r"|\bruff\b|flake8|pylint|\bmypy\b|pyright|eslint|\btsc\b|clippy|shellcheck|golangci"
    # build
    r"|docker\s+build|docker\s+compose\s+build|\bmake\b|npm\s+run\s+build|cargo\s+build|"
    r"go\s+build|gradle\s+build|mvn\s+package|dotnet\s+build"
    # live round-trip
    r"|\bcurl\b|\bwget\b|\bhttpie?\b|Invoke-RestMethod|Invoke-WebRequest|grpcurl|"
    r"\bnc\s+-z|psql|redis-cli|mysql\s+-|kubectl\s+(get|logs)|docker\s+(logs|exec)"
    # running the thing itself
    r"|python3?\s+\S+\.py|node\s+\S+\.js|pwsh\s+-File|\./\S+\.sh|bash\s+\S+\.sh"
)


def _evidence_pattern() -> str:
    extra = os.environ.get("LIVE_PROOF_EVIDENCE", "").strip()
    return f"{EVIDENCE}|{extra}" if extra else EVIDENCE


def decide(payload: dict[str, Any], turn: list[dict[str, Any]]) -> None:
    # Only gate turns that changed something. A read-only answer is not a
    # deployment claim, and gating it is how a hook earns its way to disabled.
    if not written_paths(turn):
        return

    # The closing message is the one a human reads as the verdict.
    closing = assistant_text(turn, last_message_only=True)
    if not matches(CLAIM, closing):
        return

    # Stated as unverified -> that is a legitimate, honest ending.
    if matches(EXEMPTION, assistant_text(turn)):
        return

    commands = shell_commands(turn)
    pattern = _evidence_pattern()
    if any(matches(pattern, cmd) for cmd in commands):
        return

    ran = "nothing was run at all" if not commands else "no command in it exercised the change"
    block(
        f"Live-proof check: this turn changed files and ends by claiming the work is "
        f"done/fixed/working/deployed, but {ran}.\n"
        "\n"
        "green / 200 / deployed != done. Before ending, one of these must have actually run "
        "and been capable of failing — strongest last:\n"
        "  1. lint / type-check clean on the changed files\n"
        "  2. a test that runs and passes (and that you have seen fail when the thing breaks)\n"
        "  3. output diffed against the spec\n"
        "  4. a LIVE round-trip: the real request, against the real running thing, showing "
        "real data come back\n"
        "\n"
        "Then ask the question that catches the inert-feature class: could this return "
        "\"nothing\" for a reason other than there being nothing? Wrong key, missing auth on "
        "an internal call, a path that does not exist, an exception swallowed at debug level, "
        "a config default standing in for the value you thought you set. Each of those "
        "produces a green run over nothing at all.\n"
        "\n"
        "If it genuinely cannot be exercised here (air-gapped, pre-deploy, destructive), say "
        "so in those words — \"unverified because <reason>\" — and record it. An unverified "
        "claim that is labelled unverified is fine. One wearing the word \"done\" is not."
    )


if __name__ == "__main__":
    run_hook(decide)
