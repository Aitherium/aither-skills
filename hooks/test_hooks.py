#!/usr/bin/env python3
"""Self-test for the Stop hooks in this directory.

    python3 hooks/test_hooks.py          # run every case
    python3 hooks/test_hooks.py -v       # print each case as it passes

WHY IT DRIVES SUBPROCESSES
    A hook that imports cleanly can still be a no-op: the thing that matters is
    whether the real script, handed real stdin, writes a real block decision to
    stdout. So every case here spawns the actual file the way the agent will,
    with a transcript on disk, and asserts on the JSON that comes back.

    Each case asserts a specific decision, so each case can fail. Break a hook
    (drop the block() call, widen a pattern) and cases go red — that is the
    property being bought here, and it is the one the skills themselves demand.

EXIT
    0 = every case passed        1 = at least one failed
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEBT_HOOK = os.path.join(HERE, "stop_debt_ledger.py")
LIVE_HOOK = os.path.join(HERE, "stop_live_proof.py")
AUTO_HOOK = os.path.join(HERE, "stop_automation_gap.py")


# ------------------------------------------------------------------ transcripts


def user(text: str) -> dict:
    return {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}


def assistant(text: str = "", tools: list[tuple[str, dict]] | None = None) -> dict:
    content: list[dict] = []
    if text:
        content.append({"type": "text", "text": text})
    for name, tool_input in tools or []:
        content.append({"type": "tool_use", "name": name, "input": tool_input})
    return {"type": "assistant", "message": {"role": "assistant", "content": content}}


def tool_result(text: str = "ok") -> dict:
    return {
        "type": "user",
        "message": {"role": "user", "content": [{"type": "tool_result", "content": text}]},
    }


def edit(path: str) -> tuple[str, dict]:
    return ("Edit", {"file_path": path, "old_string": "a", "new_string": "b"})


def run(path: str) -> tuple[str, dict]:
    return ("Bash", {"command": path})


# ------------------------------------------------------------------ hook driver


def invoke(hook: str, entries: list[dict], *, stop_hook_active: bool = False, env: dict | None = None,
           write_transcript: bool = True) -> dict:
    """Run `hook` exactly as the agent would; return its parsed stdout."""
    with tempfile.TemporaryDirectory() as tmp:
        transcript = os.path.join(tmp, "transcript.jsonl")
        if write_transcript:
            with open(transcript, "w", encoding="utf-8") as fh:
                for e in entries:
                    fh.write(json.dumps(e) + "\n")
        payload = {
            "session_id": "selftest",
            "transcript_path": transcript,
            "cwd": tmp,
            "hook_event_name": "Stop",
            "stop_hook_active": stop_hook_active,
        }
        child_env = dict(os.environ)
        # Do not let the developer's own configuration change the answers.
        for key in ("DEBT_LEDGER", "DEBT_LEDGER_IGNORE", "LIVE_PROOF_EVIDENCE",
                    "AUTOMATION_BACKLOG", "AUTOMATION_GAP_REPEAT", "AUTOMATION_GAP_CHAIN",
                    "AUTOMATION_GAP_SESSIONS", "AUTOMATION_GAP_MAX_BLOCKS",
                    "AUTOMATION_GAP_OFF"):
            child_env.pop(key, None)
        child_env["CLAUDE_PROJECT_DIR"] = tmp
        child_env.update(env or {})
        proc = subprocess.run(
            [sys.executable, hook],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=child_env,
        )
    if proc.returncode != 0:
        raise AssertionError(f"hook exited {proc.returncode}; stderr={proc.stderr.strip()}")
    out = proc.stdout.strip()
    if not out:
        raise AssertionError(f"hook wrote nothing to stdout; stderr={proc.stderr.strip()}")
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"hook stdout was not JSON: {out!r} ({exc})") from None


# ------------------------------------------------------------------------ cases

CASES: list[tuple[str, str, dict]] = []


def case(name: str):
    def wrap(fn):
        CASES.append((name, fn.__doc__ or "", fn))
        return fn

    return wrap


def expect_block(result: dict, must_mention: str = "") -> None:
    if result.get("decision") != "block":
        raise AssertionError(f"expected a block, got {result!r}")
    reason = result.get("reason", "")
    if not reason.strip():
        raise AssertionError("blocked with an empty reason — the agent would learn nothing")
    if must_mention and must_mention.lower() not in reason.lower():
        raise AssertionError(f"block reason never mentions {must_mention!r}: {reason[:200]!r}")


def expect_allow(result: dict) -> None:
    if result.get("decision") == "block":
        raise AssertionError(f"expected the turn to end, got a block: {result.get('reason','')[:200]!r}")


# --- debt ledger -------------------------------------------------------------


@case("debt: code changed, ledger untouched -> BLOCK")
def _(fn=None):
    """The whole point of the gate."""
    expect_block(
        invoke(DEBT_HOOK, [user("fix the parser"), assistant("Patched it.", [edit("src/parser.py")])]),
        must_mention="TECH_DEBT.md",
    )


@case("debt: ledger edited in the same turn -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            DEBT_HOOK,
            [
                user("fix the parser"),
                assistant("", [edit("src/parser.py"), edit("TECH_DEBT.md")]),
                assistant("Patched it and logged the shortcut."),
            ],
        )
    )


@case("debt: stated exemption -> allow")
def _(fn=None):
    """"no new debt: <why>" is the escape hatch, and it must actually work."""
    expect_allow(
        invoke(
            DEBT_HOOK,
            [
                user("rename the field"),
                assistant("", [edit("src/parser.py")]),
                assistant("Renamed. Checked, no new debt: pure rename, no behaviour change."),
            ],
        )
    )


@case("debt: ledger written by a shell command -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            DEBT_HOOK,
            [
                user("fix it"),
                assistant("", [edit("src/parser.py"), run("cat >> TECH_DEBT.md <<'EOF'\n| D-9 | ... |\nEOF")]),
                assistant("Done."),
            ],
        )
    )


@case("debt: read-only turn -> allow")
def _(fn=None):
    expect_allow(
        invoke(DEBT_HOOK, [user("what does this do?"), assistant("", [run("grep -rn foo .")]),
                           assistant("It parses the header.")])
    )


@case("debt: loop guard (stop_hook_active) -> allow")
def _(fn=None):
    """Without this a block would re-fire forever."""
    expect_allow(
        invoke(
            DEBT_HOOK,
            [user("fix the parser"), assistant("Patched it.", [edit("src/parser.py")])],
            stop_hook_active=True,
        )
    )


@case("debt: DEBT_LEDGER_IGNORE covers the edit -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            DEBT_HOOK,
            [user("fix a typo"), assistant("Fixed.", [edit("docs/intro.md")])],
            env={"DEBT_LEDGER_IGNORE": "docs/*"},
        )
    )


@case("debt: DEBT_LEDGER renames the ledger -> BLOCK naming the new file")
def _(fn=None):
    expect_block(
        invoke(
            DEBT_HOOK,
            [user("fix the parser"), assistant("Patched it.", [edit("src/parser.py")])],
            env={"DEBT_LEDGER": "DEBT.md"},
        ),
        must_mention="DEBT.md",
    )


@case("debt: edits before the last human prompt are a previous turn -> allow")
def _(fn=None):
    """Turn boundary. Otherwise one un-ledgered edit blocks every later turn."""
    expect_allow(
        invoke(
            DEBT_HOOK,
            [
                user("fix the parser"),
                assistant("Patched it.", [edit("src/parser.py")]),
                user("now explain what you did"),
                assistant("It was an off-by-one in the header scan."),
            ],
        )
    )


@case("debt: missing transcript -> allow (never break a session)")
def _(fn=None):
    expect_allow(invoke(DEBT_HOOK, [], write_transcript=False))


@case("debt: malformed transcript line is skipped, gate still fires")
def _(fn=None):
    with tempfile.TemporaryDirectory() as tmp:
        transcript = os.path.join(tmp, "t.jsonl")
        with open(transcript, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(user("fix the parser")) + "\n")
            fh.write("{not json at all\n")
            fh.write(json.dumps(assistant("Patched.", [edit("src/parser.py")])) + "\n")
            fh.write('{"type":"assistant","message":{"role":"assis')  # truncated flush
        proc = subprocess.run(
            [sys.executable, DEBT_HOOK],
            input=json.dumps({"transcript_path": transcript, "stop_hook_active": False}),
            capture_output=True,
            text=True,
        )
        expect_block(json.loads(proc.stdout.strip()), must_mention="TECH_DEBT.md")


# --- live proof --------------------------------------------------------------


@case("live: claimed done, nothing run -> BLOCK")
def _(fn=None):
    expect_block(
        invoke(LIVE_HOOK, [user("fix the auth gate"), assistant("Fixed — the gate now denies on error.",
                                                               [edit("src/authz.py")])]),
        must_mention="done",
    )


@case("live: claimed done, tests were run -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            LIVE_HOOK,
            [
                user("fix the auth gate"),
                assistant("", [edit("src/authz.py"), run("python -m pytest tests/test_authz.py -x")]),
                tool_result("3 passed"),
                assistant("Fixed and the suite passes."),
            ],
        )
    )


@case("live: claimed done, only an irrelevant command -> BLOCK")
def _(fn=None):
    """`git status` is not a check that can fail on the change."""
    expect_block(
        invoke(
            LIVE_HOOK,
            [
                user("fix the auth gate"),
                assistant("", [edit("src/authz.py"), run("git status --short")]),
                assistant("All fixed."),
            ],
        )
    )


@case("live: stated as unverified -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            LIVE_HOOK,
            [
                user("fix the auth gate"),
                assistant("", [edit("src/authz.py")]),
                assistant("Change is complete but unverified: the service is not running here."),
            ],
        )
    )


@case("live: no completion claim -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            LIVE_HOOK,
            [
                user("start on the auth gate"),
                assistant("", [edit("src/authz.py")]),
                assistant("First pass at the deny path is in; still need to handle the None case."),
            ],
        )
    )


@case("live: claim in an earlier message only, closing text neutral -> allow")
def _(fn=None):
    """Only the closing message is the verdict a human reads."""
    expect_allow(
        invoke(
            LIVE_HOOK,
            [
                user("fix the auth gate"),
                assistant("The first hunk is fixed.", [edit("src/authz.py")]),
                assistant("Next I want to look at how the token is minted before going further."),
            ],
        )
    )


@case("live: nothing was changed -> allow")
def _(fn=None):
    expect_allow(
        invoke(LIVE_HOOK, [user("is the gate ok?"), assistant("", [run("grep -n 'return True' src/authz.py")]),
                           assistant("Yes, that path is fine — it is already fixed upstream.")])
    )


@case("live: a live round-trip counts as evidence -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            LIVE_HOOK,
            [
                user("deploy the fix"),
                assistant("", [edit("src/authz.py"), run("curl -sS http://127.0.0.1:8080/whoami")]),
                tool_result('{"tenant":"acme"}'),
                assistant("Deployed and the live round-trip returns the tenant."),
            ],
        )
    )


@case("live: LIVE_PROOF_EVIDENCE extends the patterns -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            LIVE_HOOK,
            [
                user("fix it"),
                assistant("", [edit("src/authz.py"), run("bazel test //src:authz_test")]),
                assistant("Fixed."),
            ],
            env={"LIVE_PROOF_EVIDENCE": r"bazel\s+test"},
        )
    )


@case("live: loop guard (stop_hook_active) -> allow")
def _(fn=None):
    expect_allow(
        invoke(
            LIVE_HOOK,
            [user("fix the auth gate"), assistant("Fixed.", [edit("src/authz.py")])],
            stop_hook_active=True,
        )
    )


# --- automation gap ----------------------------------------------------------


def backlog(tmp_marker: str) -> dict:
    """An env pointing the gate at a backlog file written on the fly."""
    return {"AUTOMATION_BACKLOG": tmp_marker}


@case("automation: same mutation 3x, nothing recorded -> BLOCK")
def _(fn=None):
    """The whole point of the gate: a loop typed out by hand."""
    expect_block(
        invoke(AUTO_HOOK, [
            user("restart the web tier"),
            assistant("", [run("docker restart web-1")]),
            assistant("", [run("docker restart web-2")]),
            assistant("All three back up.", [run("docker restart web-3")]),
        ]),
        must_mention="docker restart",
    )


@case("automation: a hand-typed mutating chain -> BLOCK")
def _(fn=None):
    expect_block(
        invoke(AUTO_HOOK, [
            user("rebuild the container"),
            assistant("Done.", [run(
                "docker stop api && docker rm api && docker run --name api img "
                "&& systemctl status api")]),
        ]),
        must_mention="AT002",
    )


@case("automation: repeated READS are exploration -> allow")
def _(fn=None):
    """Automating a debugging loop would be noise; a rule that floods gets switched off."""
    expect_allow(
        invoke(AUTO_HOOK, [
            user("why is it down?"),
            assistant("", [run("docker ps")]),
            assistant("", [run("docker ps -a")]),
            assistant("Nothing running.", [run("docker ps | grep api")]),
        ])
    )


@case("automation: ordinary dev flow -> allow")
def _(fn=None):
    expect_allow(
        invoke(AUTO_HOOK, [
            user("land the fix"),
            assistant("", [run("pytest -x")]),
            assistant("", [run("pytest -x")]),
            assistant("", [run("pytest -x")]),
            assistant("Green.", [run("git commit -m fix")]),
        ])
    )


@case("automation: running an EXISTING script -> allow")
def _(fn=None):
    """Running automation is the outcome this gate exists to produce."""
    expect_allow(
        invoke(AUTO_HOOK, [
            user("deploy"),
            assistant("", [run("./deploy.sh staging")]),
            assistant("", [run("./deploy.sh canary")]),
            assistant("Shipped.", [run("./deploy.sh prod")]),
        ])
    )


@case("automation: inline one-off analysis -> allow")
def _(fn=None):
    """A signature cannot say WHICH analysis it was, so these are counted, not judged."""
    expect_allow(
        invoke(AUTO_HOOK, [
            user("how many rows?"),
            assistant("", [run("python -c 'import json;print(1)'")]),
            assistant("", [run("python -c 'import json;print(2)'")]),
            assistant("About 40k.", [run("python -c 'import json;print(3)'")]),
        ])
    )


@case("automation: ran no commands at all -> allow")
def _(fn=None):
    expect_allow(
        invoke(AUTO_HOOK, [user("what does this do?"), assistant("It parses the config.")])
    )


@case("automation: a recorded wontfix discharges the shape -> allow")
def _(fn=None):
    """The escape hatch, and it is durable — the next session does not re-ask."""
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "backlog.yaml")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("version: 1\nentries:\n"
                     "  - signature: 'docker restart'\n    status: wontfix\n"
                     "    reason: one-off during an incident\n")
        expect_allow(
            invoke(AUTO_HOOK, [
                user("restart the web tier"),
                assistant("", [run("docker restart web-1")]),
                assistant("", [run("docker restart web-2")]),
                assistant("Back up.", [run("docker restart web-3")]),
            ], env=backlog(path))
        )


@case("automation: an `open` row is not a decision -> BLOCK")
def _(fn=None):
    """`open` means found, not answered. Only automated/wontfix discharge."""
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "backlog.yaml")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("version: 1\nentries:\n"
                     "  - signature: 'docker restart'\n    status: open\n")
        expect_block(
            invoke(AUTO_HOOK, [
                user("restart the web tier"),
                assistant("", [run("docker restart web-1")]),
                assistant("", [run("docker restart web-2")]),
                assistant("Back up.", [run("docker restart web-3")]),
            ], env=backlog(path)),
            must_mention="docker restart",
        )


@case("automation: AUTOMATION_GAP_OFF disables it -> allow")
def _(fn=None):
    expect_allow(
        invoke(AUTO_HOOK, [
            user("restart the web tier"),
            assistant("", [run("docker restart web-1")]),
            assistant("", [run("docker restart web-2")]),
            assistant("Back up.", [run("docker restart web-3")]),
        ], env={"AUTOMATION_GAP_OFF": "1"})
    )


# ---------------------------------------------------------------------- runner


def main() -> int:
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    failures: list[tuple[str, str]] = []
    for name, _doc, fn in CASES:
        try:
            fn()
        except AssertionError as exc:
            failures.append((name, str(exc)))
            print(f"FAIL  {name}\n        {exc}")
        except Exception as exc:  # noqa: BLE001 - report, do not mask
            failures.append((name, f"{type(exc).__name__}: {exc}"))
            print(f"ERROR {name}\n        {type(exc).__name__}: {exc}")
        else:
            if verbose:
                print(f"ok    {name}")

    print(f"\n{len(CASES) - len(failures)}/{len(CASES)} hook cases passed.")
    if failures:
        print(f"{len(failures)} failed:")
        for name, why in failures:
            print(f"  - {name}: {why}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
