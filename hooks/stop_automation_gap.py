#!/usr/bin/env python3
"""Stop hook — the automation gate (see skills/automate-the-manual.md).

Blocks a turn that did work BY HAND which will have to be done by hand again,
and keeps asking until every such shape has a recorded decision: it became an
automation, or somebody deliberately decided it should not.

    manual toil + no decision recorded   -> block, listing each shape
    every shape accounted in the backlog -> allow
    nothing repeated, chained, recurring -> allow

WHY THIS IS A HOOK AND NOT A HABIT
    The end of a session is exactly when the knowledge is complete and the
    motivation is gone. Nobody finishes a four-hour repair and then
    spontaneously writes the script — the work is done, the system is green,
    and the procedure evaporates into a transcript nobody re-reads. Asked at
    any other moment the question is unanswerable; asked here it is trivial,
    because the commands are right there.

WHAT COUNTS AS TOIL — three rules, deliberately narrow

    AT001  the same command SHAPE run >= 3 times in one turn. Restarting five
           containers one at a time is a loop; the loop is the script.
    AT002  a hand-typed chain of >= 3 steps containing a mutation. That is a
           runbook being executed from memory, which is the state a runbook is
           in immediately before it is wrong.
    AT003  the same shape run in >= 2 DISTINCT sessions. The strongest signal,
           and the only one a single transcript cannot see.

    Read-only commands are eligible for AT003 ONLY. Repeating a read inside one
    turn is debugging, and flagging it is noise; repeating the same read across
    sessions is a dashboard that does not exist. A rule that floods gets
    switched off, so the within-turn rules see mutations only.

    Commands that ARE already automation (`pytest`, a `./script.sh`, `npm run
    build`) never count. Running a script is the outcome, not the defect.

RUN IT BY HAND TOO
    python3 stop_automation_gap.py --report        # this session's candidates
    python3 stop_automation_gap.py --check         # gate the backlog file
    python3 stop_automation_gap.py --self-test     # prove it can still fail

WHAT THIS IS AND IS NOT
    It is a floor. Three rules over command lines cannot know which work was
    worth automating — only that it was done twice. What it buys is that
    walking away from a repeated procedure becomes a DELIBERATE act
    (`status: wontfix`, with a reason) rather than the default one.

WIRE IT UP        see README.md
CONFIGURE         AUTOMATION_BACKLOG        path to the decision file
                  AUTOMATION_GAP_REPEAT     AT001 threshold (3)
                  AUTOMATION_GAP_CHAIN      AT002 threshold (3)
                  AUTOMATION_GAP_SESSIONS   AT003 threshold (2)
                  AUTOMATION_GAP_MAX_BLOCKS raises per batch before it gives up (3)
                  AUTOMATION_GAP_OFF=1      disable (says so on stderr; never silent)
SELF-TEST         python3 hooks/test_hooks.py
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from datetime import datetime
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hook_common import (  # noqa: E402
    allow,
    block,
    current_turn,
    load_transcript,
    read_payload,
    shell_commands,
)

REPEAT_MIN = int(os.environ.get("AUTOMATION_GAP_REPEAT", "3"))
CHAIN_MIN = int(os.environ.get("AUTOMATION_GAP_CHAIN", "3"))
SESSIONS_MIN = int(os.environ.get("AUTOMATION_GAP_SESSIONS", "2"))
MAX_BLOCKS = int(os.environ.get("AUTOMATION_GAP_MAX_BLOCKS", "3"))

STATUSES = ("open", "automated", "wontfix")


# --------------------------------------------------------------------- layout


def project_dir() -> str:
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and os.path.isdir(env):
        return env
    here = os.getcwd()
    while True:
        if os.path.exists(os.path.join(here, ".git")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return os.getcwd()
        here = parent


def backlog_path() -> str:
    env = os.environ.get("AUTOMATION_BACKLOG")
    if env:
        return env
    return os.path.join(project_dir(), ".claude", "automation-backlog.yaml")


def sightings_path() -> str:
    return os.path.join(project_dir(), ".claude", ".automation-sightings.jsonl")


def state_path() -> str:
    return os.path.join(project_dir(), ".claude", ".automation-gap-state.json")


# ------------------------------------------------------------------- lexicon

# Binaries whose FIRST ARGUMENT carries the meaning. `docker restart` and
# `docker ps` are not the same act and must never share a signature.
MULTI_VERB = {
    "git", "docker", "podman", "npm", "pnpm", "yarn", "gh", "systemctl",
    "journalctl", "kubectl", "pip", "pip3", "apt", "apt-get", "dnf", "cargo",
    "go", "az", "aws", "gcloud", "helm", "terraform", "docker-compose", "uv",
    "poetry", "conda", "openssl", "ip", "wsl", "compose", "tailscale",
    "nvidia-smi", "awgit", "aither",
}

# Verbs that CHANGE something. Only these can raise AT001/AT002.
MUTATING = {
    "restart", "start", "stop", "rm", "rmi", "kill", "create", "exec", "cp",
    "mv", "build", "push", "pull", "apply", "deploy", "install", "uninstall",
    "chmod", "chown", "mkdir", "rmdir", "ln", "tee", "prune", "load", "save",
    "tag", "up", "down", "recreate", "scale", "enable", "disable", "mask",
    "unmask", "daemon-reload", "set", "unset", "rotate", "migrate", "sync",
    "reload", "reset", "drain", "cordon", "uncordon", "write", "put", "post",
    "delete", "purge", "truncate", "dd", "mount", "umount", "register",
    "provision", "teardown", "terminate", "systemctl", "quadlet", "unregister",
}

# Read-only / navigational. Eligible for AT003 only.
NAV_BINARIES = {
    "ls", "ll", "dir", "cat", "bat", "head", "tail", "less", "more", "grep",
    "rg", "ag", "find", "fd", "wc", "echo", "printf", "pwd", "cd", "which",
    "where", "type", "stat", "du", "df", "file", "sed", "awk", "cut", "sort",
    "uniq", "tr", "jq", "yq", "column", "tree", "date", "whoami", "hostname",
    "env", "printenv", "ps", "top", "htop", "free", "uptime", "id", "history",
    "diff", "md5sum", "sha256sum", "basename", "dirname", "realpath", "test",
    "sleep", "clear", "true", "false", "get-childitem", "select-string",
    "get-content", "measure-object", "where-object", "select-object",
}

# Subcommands that are reads even on a mutating binary.
NAV_SUBCOMMANDS = {
    "ps", "images", "inspect", "logs", "status", "log", "diff", "show",
    "branch", "list", "ls", "get", "describe", "version", "info", "top",
    "stats", "config", "which", "history", "port", "search", "cat-file",
    "rev-parse", "blame", "help",
}

# Already automation, or ordinary dev flow nobody wants a script for.
DENY_SIGNATURES = {
    "pytest", "py.test", "ruff", "mypy", "pyright", "flake8", "pylint",
    "black", "isort", "eslint", "tsc", "jest", "vitest", "shellcheck",
    "actionlint", "make", "cmake", "ctest", "tox", "nox", "pester",
    "invoke-pester", "node", "npx", "deno", "bun",
    "git add", "git commit", "git push", "git pull", "git fetch", "git status",
    "git diff", "git log", "git show", "git checkout", "git switch",
    "git branch", "git stash", "git merge", "git rebase", "git restore",
    "git worktree", "git remote", "git tag", "git clone", "git rev-parse",
    "npm test", "npm run", "npm ci", "npm install", "npm i",
    "pnpm run", "yarn run", "cargo test", "cargo build", "go test", "go build",
    "gh pr", "gh issue", "gh run", "gh api", "gh workflow", "gh release",
}

_SCRIPT_INVOCATION = re.compile(
    r"""(?xi)
    ^(?:python3?|py|pwsh|powershell|bash|sh|zsh|perl|ruby|node)\b
    (?: [^|;&]*? \S+\.(?:py|ps1|sh|bash|pl|rb|js|mjs)\b
      | \s+-m\s+[A-Za-z_][\w.]*
    )
    | ^\.{0,2}/\S+\.(?:sh|py|ps1)\b
    """
)

# Inline code is EXCLUDED from every rule. Ad-hoc analysis written inline is
# the right way to answer a one-off question, and a signature cannot say WHICH
# analysis it was — so every heredoc in a session collapses into one useless
# `python <<EOF` row. Measured on a real 893-command transcript, that was four
# of the top ten clusters and none of them actionable. Counted instead.
_INLINE_CODE = re.compile(
    r"""(?xi)
    (?:^|\s)(?:python3?|py|pwsh|powershell|bash|sh|zsh|node|perl|ruby)
    (?:\.exe)?\s+ (?:-\S+\s+)* (?:-[a-z]*c|-s|-Command|-EncodedCommand)\b
    | <<-?\s*['"]?[A-Za-z_]+['"]?
    """
)

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_STEP_SPLIT = re.compile(r"\s*(?:&&|\|\||;|\n|\|)\s*")
_QUOTED = re.compile(r"""^(?P<q>['"])(?P<body>.*)(?P=q)$""", re.DOTALL)

# A loop HEADER is scope, not a step. Stripping only the keyword leaves
# `c in a b` and signs the command after a loop VARIABLE.
_LOOP_HEADER = re.compile(r"^\s*(for|while|until|foreach|if|elif|case)\b", re.IGNORECASE)
_CONTROL = {"do", "then", "else", "{", "("}
_SKIP_STEPS = {"cd", "set-location", "pushd", "popd", "echo", "printf", "set",
               "export", "true", "sleep", "done", "fi", "esac", "}", ")"}

# PowerShell names its reads: `Get-X | Where-Object | Select-Object` is a
# four-step READ pipeline, not a runbook.
_PS_READ_VERB = re.compile(
    r"^(get|test|show|measure|select|where|format|out|compare|find|resolve"
    r"|convertto|convertfrom)-", re.IGNORECASE)

# What a command name can look like. The two-character floor is deliberate:
# `ls`/`cp` are real, a bare `n` out of a mangled `$'\n'` is a parse artifact
# and it had its own backlog row before this existed.
_PLAUSIBLE_BINARY = re.compile(r"^[a-z][a-z0-9._+-]+$")

_VARIABLE = re.compile(
    r"""(?x)
    ^-  | ^/  | ^[A-Za-z]:[\\/]  | [\\/]  | ^\d  | ^\$
    | \.(py|ps1|sh|yaml|yml|json|md|txt|log|jsonl|toml|ini|cfg)$
    | ^@
    """
)


class Candidate:
    def __init__(self, rule: str, signature: str, sample: str, count: int = 1,
                 sessions: int = 1, why: str = ""):
        self.rule = rule
        self.signature = signature
        self.sample = sample
        self.count = count
        self.sessions = sessions
        self.why = why

    def lane(self) -> str:
        return suggest_lane(self.signature, self.sample)


# --------------------------------------------------------------- normalising


def _unquote(text: str) -> str:
    m = _QUOTED.match(text.strip())
    return m.group("body") if m else text.strip()


def _strip_prefixes(tokens: List[str]) -> List[str]:
    out = list(tokens)
    while out:
        head = out[0].lower()
        if _ENV_ASSIGN.match(out[0]) and "=" in out[0]:
            # `s=$(docker ps ...)` is a call to docker, not an assignment to
            # drop: dropping it leaves a FLAG as the binary.
            value = out[0].split("=", 1)[1]
            if value.startswith("$(") or value.startswith("`"):
                inner = " ".join([value.lstrip("$(`")] + out[1:])
                return _strip_prefixes(inner.rstrip(")`").split())
            out.pop(0)
            continue
        if head in {"sudo", "time", "nohup", "command", "exec", "\\", "stdbuf", "nice"}:
            out.pop(0)
            continue
        # `timeout 300 python tool.py` is a call to tool.py — without this the
        # deny list never sees the script and a wrapped invocation of an
        # EXISTING automation is reported as toil.
        if head in {"timeout", "ionice", "taskset"} and len(out) > 2:
            out.pop(0)
            while out and (out[0].startswith("-") or re.match(r"^[\d.]+[smhd]?$", out[0])):
                out.pop(0)
            continue
        break
    return out


def _unwrap_remote(tokens: List[str]) -> Tuple[List[str], str]:
    """Peel `ssh host '<cmd>'` / `wsl -d X <cmd>` down to the real work.

    The wrapper stays as a prefix: the same verb run locally and run on a
    remote host are different acts with different failure modes.
    """
    if not tokens:
        return tokens, ""
    head = tokens[0].lower()

    if head == "wsl" or head.endswith("wsl.exe"):
        i = 1
        while i < len(tokens):
            tok = tokens[i]
            if tok in {"-d", "--distribution", "-u", "--user", "-e", "--exec"}:
                i += 2
                continue
            if tok == "--":
                i += 1
                break
            if tok.startswith("-"):
                i += 1
                continue
            break
        return tokens[i:], "wsl:"

    if head == "ssh":
        i, seen_host = 1, False
        while i < len(tokens):
            tok = tokens[i]
            if tok.startswith("-"):
                i += 2 if tok in {"-i", "-p", "-o", "-l", "-F"} else 1
                continue
            if not seen_host:
                seen_host = True
                i += 1
                continue
            break
        return _unquote(" ".join(tokens[i:])).split(), "ssh:"

    return tokens, ""


def _strip_control(step: str) -> str:
    toks = step.split()
    while toks and toks[0].lower() in _CONTROL:
        toks.pop(0)
    return " ".join(toks)


def _primary_step(command: str) -> Tuple[str, bool]:
    """The step that carries the meaning, and whether it sat inside a loop."""
    raw = command.strip()
    looped = bool(re.match(r"^\s*(for|while|until|foreach)\b", raw))
    steps = [s for s in _STEP_SPLIT.split(raw) if s.strip()]
    for step in steps:
        if _LOOP_HEADER.match(step):
            continue
        bare = _strip_control(step)
        toks = _strip_prefixes(bare.split())
        if not toks or toks[0].lower() in _SKIP_STEPS:
            continue
        return bare.strip(), looped
    fallback = _strip_control(steps[0]).strip() if steps else raw
    return (fallback or raw), looped


def signature_of(command: str) -> str:
    """A stable shape for a command, with the variable parts removed.

    `docker restart web-1` and `docker restart web-2` share a signature;
    `docker restart` and `docker ps` do not. Returns "" for inline code and
    for parse artifacts, which means "not judgeable" everywhere downstream.
    """
    if _INLINE_CODE.search(command):
        return ""
    step, looped = _primary_step(command)
    tokens = _strip_prefixes(step.split())
    tokens, prefix = _unwrap_remote(tokens)
    tokens = _strip_prefixes(tokens)
    if not tokens:
        return ""

    binary = os.path.basename(tokens[0]).lower().strip("'\"")
    binary = re.sub(r"\.(exe|cmd|bat)$", "", binary)
    if not _PLAUSIBLE_BINARY.match(binary):
        return ""
    parts = [binary]

    if binary in {"python", "python3", "py", "pwsh", "powershell", "bash", "sh"}:
        for tok in tokens[1:]:
            if tok in {"-m", "-File"}:
                parts.append(tok)
                continue
            if tok.startswith("-"):
                continue
            parts.append(os.path.basename(tok))
            break
    elif binary in MULTI_VERB:
        for tok in tokens[1:]:
            if tok.startswith("-"):
                continue
            # ...and skip a FLAG'S VALUE. `git -C /some/path status` otherwise
            # signs as a bare `git`, folding every subcommand in the session
            # into one row named after the binary.
            if _VARIABLE.search(tok.strip("'\"")):
                continue
            parts.append(os.path.basename(tok.strip("'\"")).lower())
            break

    kept = [parts[0]] + [p for p in parts[1:]
                         if not _VARIABLE.search(p) or p in {"-m", "-File"}]
    shape = " ".join(kept).strip()
    if not shape:
        return ""
    return ("loop:" if looped else "") + prefix + shape


def _is_denied(command: str, sig: str) -> bool:
    bare = sig.split(":")[-1]
    if bare in DENY_SIGNATURES or bare.split(" ")[0] in DENY_SIGNATURES:
        return True
    step, _ = _primary_step(command)
    peeled = " ".join(_strip_prefixes(step.split()))
    return bool(_SCRIPT_INVOCATION.match(peeled.strip())
                or _SCRIPT_INVOCATION.match(step.strip()))


def _is_mutation(command: str, sig: str, strict: bool = False) -> bool:
    """Does this change something?

    `strict` drops the unknown-binary fallback. Chains use it: AT002 claims a
    runbook was executed from memory, and that needs a verb we can name.
    """
    bare = sig.split(":")[-1]
    parts = bare.split()
    if not parts:
        return False
    binary, sub = parts[0], (parts[1] if len(parts) > 1 else "")
    if sub and sub in NAV_SUBCOMMANDS:
        return False
    if _PS_READ_VERB.match(binary):
        return False
    if binary in NAV_BINARIES and binary not in MUTATING:
        return False
    if binary in MUTATING or sub in MUTATING:
        return True
    if binary in {"curl", "wget", "http", "invoke-restmethod", "invoke-webrequest"}:
        write_method = (r"(?i)-X\s*(POST|PUT|PATCH|DELETE)|--data|-d\s"
                        r"|-Method\s*(Post|Put|Patch|Delete)")
        return bool(re.search(write_method, command))
    if strict:
        return False
    return binary not in NAV_BINARIES


def _is_generic_shell(sig: str) -> bool:
    """Is this shape just... the shell?

    AT003 says "you have run this in two different sessions, so it is a job
    nobody wrote". That is true of `podman ps` and `curl /health`; it is
    nonsense for `ls`, `grep` and `sed`, which appear in EVERY session by
    definition and cannot be automated away. Measured on a real transcript,
    leaving them in made the four loudest AT003 findings `ls` (40x), `grep`
    (152x), `sed` (74x) and `head` (15x) — a flood, and a flood gets the whole
    gate switched off.

    A bare nav binary is plumbing. A nav SUBCOMMAND on a domain tool
    (`podman ps`, `systemctl status`) is a probe, and a probe run every
    session is a dashboard that does not exist yet.
    """
    bare = sig.split(":")[-1]
    parts = bare.split()
    return len(parts) == 1 and parts[0] in NAV_BINARIES


def suggest_lane(signature: str, sample: str = "") -> str:
    bare = signature.split(":")[-1]
    binary = bare.split(" ")[0]
    blob = (signature + " " + sample).lower()
    if binary in {"curl", "wget", "http", "invoke-restmethod", "invoke-webrequest"} \
            or "/health" in blob:
        return "a scheduled probe that ALERTS — only a live check can see this"
    if binary in {"docker", "podman", "systemctl", "docker-compose", "kubectl"} \
            or "wsl:" in signature or "ssh:" in signature:
        return ("an idempotent script that re-asserts after acting, "
                "+ a schedule if it should run unattended")
    if binary in {"grep", "rg", "find", "fd", "select-string", "ls"}:
        return "a CI check with a self-test that proves it can fail"
    if binary in {"gh", "git"}:
        return "a CI workflow, or a script in the repo's tools directory"
    return "a script if it is one procedure; a SKILL if the hard part is judgement, not keystrokes"


def count_inline_code(commands: Sequence[str]) -> int:
    """One-off inline scripts — the rules' deliberate blind spot, made visible."""
    return sum(1 for c in commands if c and _INLINE_CODE.search(c))


# ------------------------------------------------------------------ sightings


class Sightings:
    """Cross-session memory: which shapes have been typed, in how many sessions."""

    def __init__(self, path: Optional[str] = None):
        self.path = path or sightings_path()
        self._sessions: Dict[str, set] = {}
        self._load()

    def _load(self) -> None:
        if not os.path.isfile(self.path):
            return
        try:
            with open(self.path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue  # a partially-flushed last line is normal
                    sig = row.get("signature")
                    if isinstance(sig, str) and sig:
                        self._sessions.setdefault(sig, set()).add(row.get("session") or "?")
        except OSError:
            return

    def sessions_for(self, signature: str, current_session: str = "") -> int:
        seen = set(self._sessions.get(signature, ()))
        if current_session:
            seen.add(current_session)
        return len(seen)

    def record(self, signature: str, sample: str, session: str) -> None:
        if not signature:
            return
        if session and session in self._sessions.get(signature, set()):
            return  # one row per (signature, session); the file stays small
        self._sessions.setdefault(signature, set()).add(session or "?")
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({
                    "signature": signature,
                    "sample": sample[:200],
                    "session": session or "?",
                    "at": datetime.now().isoformat(timespec="seconds"),
                }) + "\n")
        except OSError as exc:
            # Never break a session — but a SILENT failure here would disable
            # AT003 forever, which is the rule that needs this file most.
            sys.stderr.write("[warn] sighting not recorded: %s\n" % exc)


# --------------------------------------------------------------------- rules


def candidates_from_commands(commands: Sequence[str],
                             sightings: Optional[Sightings] = None,
                             session_id: str = "",
                             record: bool = False) -> List[Candidate]:
    """The whole rule set. Strongest signal first (AT003, AT001, AT002)."""
    counts: Dict[str, int] = {}
    samples: Dict[str, str] = {}
    chains: List[Tuple[str, str]] = []

    for command in commands:
        if not command or not command.strip():
            continue
        sig = signature_of(command)
        if not sig or _is_denied(command, sig):
            continue
        samples.setdefault(sig, command.strip())
        counts[sig] = counts.get(sig, 0) + 1
        if record and sightings is not None:
            sightings.record(sig, command.strip(), session_id)

        steps = [s for s in _STEP_SPLIT.split(command.strip()) if s.strip()]
        if len(steps) >= CHAIN_MIN and _is_mutation(command, sig, strict=True):
            if any(_is_mutation(s, signature_of(s), strict=True)
                   for s in steps if signature_of(s)):
                chains.append((sig, command.strip()))

    out: List[Candidate] = []
    claimed = set()

    if sightings is not None:
        for sig, count in counts.items():
            if _is_generic_shell(sig):
                continue
            n = sightings.sessions_for(sig, session_id)
            if n >= SESSIONS_MIN:
                out.append(Candidate(
                    "AT003", sig, samples[sig], count, n,
                    "run by hand in %d distinct sessions — that is a scheduled job "
                    "nobody has written" % n))
                claimed.add(sig)

    for sig, count in counts.items():
        if sig in claimed or count < REPEAT_MIN:
            continue
        if not _is_mutation(samples[sig], sig):
            continue  # reads are AT003-eligible only
        out.append(Candidate(
            "AT001", sig, samples[sig], count,
            why="run %dx by hand in one turn — the loop is the script" % count))
        claimed.add(sig)

    for sig, sample in chains:
        if sig in claimed:
            continue
        steps = len([s for s in _STEP_SPLIT.split(sample) if s.strip()])
        out.append(Candidate(
            "AT002", sig, sample,
            why="a %d-step mutating procedure typed from memory — that is a runbook" % steps))
        claimed.add(sig)

    return out


# ------------------------------------------------------------------- backlog


class BacklogError(Exception):
    pass


def _parse_backlog(text: str) -> List[Dict[str, str]]:
    """Parse the small, fixed yaml subset this file uses.

    Deliberately hand-rolled: these hooks are standard-library only, so
    depending on pyyaml would mean the gate silently does not run wherever it
    is missing — and a gate that cannot run must never look like a clean pass.
    Anything it cannot parse raises, which the caller reports as DEAD.
    """
    entries: List[Dict[str, str]] = []
    current: Optional[Dict[str, str]] = None
    in_entries = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split(" #")[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        stripped = line.strip()
        if not line.startswith((" ", "\t", "-")) and stripped.endswith(":"):
            in_entries = stripped[:-1].strip() == "entries"
            continue
        if not line.startswith((" ", "\t", "-")) and ":" in stripped:
            continue  # a top-level scalar such as `version: 1`
        if not in_entries:
            continue
        if stripped in ("[]", "entries: []"):
            continue
        if stripped.startswith("- "):
            current = {}
            entries.append(current)
            stripped = stripped[2:].strip()
        if not stripped:
            continue
        if ":" not in stripped:
            raise BacklogError("line %d: cannot parse %r" % (lineno, raw.strip()))
        if current is None:
            raise BacklogError("line %d: key outside any entry" % lineno)
        key, _, value = stripped.partition(":")
        current[key.strip()] = value.strip().strip("'\"")
    return entries


class Backlog:
    def __init__(self, path: Optional[str] = None):
        self.path = path or backlog_path()
        self.entries: List[Dict[str, str]] = []
        self.parse_error = ""
        if not os.path.isfile(self.path):
            return
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                self.entries = _parse_backlog(fh.read())
        except (OSError, BacklogError) as exc:
            self.parse_error = str(exc)

    def accounted(self, signature: str) -> bool:
        return any(e.get("signature") == signature
                   and e.get("status") in ("automated", "wontfix")
                   for e in self.entries)

    def check(self) -> List[str]:
        """AB001 status enum, AB002 reasoned wontfix, AB003 real target,
        AB004 no duplicate signatures."""
        problems: List[str] = []
        seen: Dict[str, int] = {}
        root = project_dir()
        for e in self.entries:
            sig = e.get("signature", "")
            if not sig:
                problems.append("AB001 an entry has no `signature`")
                continue
            seen[sig] = seen.get(sig, 0) + 1
            status = e.get("status", "")
            if status not in STATUSES:
                problems.append("AB001 %s: status %r is not one of %s" % (sig, status, STATUSES))
            if status == "wontfix" and not e.get("reason"):
                problems.append(
                    "AB002 %s: wontfix with no reason — a hole dressed up as a decision" % sig)
            if status == "automated":
                target = e.get("target", "")
                if not target:
                    problems.append("AB003 %s: automated with no `target`" % sig)
                elif not os.path.exists(os.path.join(root, target)):
                    problems.append("AB003 %s: target does not exist: %s" % (sig, target))
        for sig, n in seen.items():
            if n > 1:
                problems.append("AB004 %s: %d entries for one signature" % (sig, n))
        return problems


# --------------------------------------------------------------------- state


def _read_state() -> Dict[str, Any]:
    try:
        with open(state_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_state(state: Dict[str, Any]) -> None:
    try:
        os.makedirs(os.path.dirname(state_path()), exist_ok=True)
        with open(state_path(), "w", encoding="utf-8") as fh:
            json.dump(state, fh)
    except OSError as exc:
        sys.stderr.write("[warn] automation gate state not written: %s\n" % exc)


def escalation(session: str, signatures: List[str]) -> Tuple[int, Dict[str, Any]]:
    """How many times this exact batch has already been raised.

    Keyed on the BATCH, not the session: a new shape resets the count, so a
    session that keeps generating toil keeps getting asked, while one
    unresolvable batch can never wedge it forever.
    """
    state = _read_state()
    key = hashlib.sha1("\n".join(sorted(signatures)).encode("utf-8")).hexdigest()[:12]
    entry = state.get(session)
    if not isinstance(entry, dict) or entry.get("key") != key:
        entry = {"key": key, "blocks": 0}
    return int(entry.get("blocks", 0)), {"state": state, "session": session, "entry": entry}


def bump(ctx: Dict[str, Any]) -> None:
    ctx["entry"]["blocks"] = int(ctx["entry"].get("blocks", 0)) + 1
    ctx["state"][ctx["session"]] = ctx["entry"]
    _write_state(ctx["state"])


# ------------------------------------------------------------------- message


def render_block(candidates: List[Candidate], path: str, blocks_so_far: int) -> str:
    lines = [
        "Automation check (skills/automate-the-manual.md): this turn did work BY HAND "
        "that will have to be done by hand again, and nothing recorded a decision "
        "about it.",
        "",
    ]
    for c in candidates:
        lines += [
            "  [%s] %s" % (c.rule, c.signature),
            "        %s" % c.why,
            "        e.g. %s" % c.sample[:160],
            "        lane: %s" % c.lane(),
            "",
        ]
    lines += [
        "Take each one to a conclusion:",
        "",
        "  1. a CHECK      static, runs in CI, with a self-test that proves it can fail",
        "  2. a SCHEDULED  probe or job that ALERTS — for anything only a live check sees",
        "  3. a SCRIPT     steps but no judgement. Idempotent, and it re-asserts after acting",
        "  4. a WORKFLOW   when it should fire on a push or a clock, not on a whim",
        "  5. a SKILL      when the hard part is the judgement and the traps, not the keystrokes",
        "",
        "Then record the outcome, one row per shape, in %s:" % path,
        "",
        "    - signature: \"<exactly the signature above>\"",
        "      status: automated        # or: wontfix",
        "      target: tools/thing.py   # required for automated; must EXIST",
        "      reason: \"...\"            # required for wontfix, one line",
        "",
        "`wontfix` is a real answer — a genuinely one-off command is not toil. It is the "
        "cheap answer that has to be a DELIBERATE one, which is the whole point of the "
        "row. What is not an answer is leaving it unrecorded: that is how the same "
        "procedure gets re-derived a third time.",
        "",
        "Do not write `automated` with a target that does not exist yet — `--check` "
        "(AB003) fails on it, and it is the cheapest possible lie this ledger can hold: "
        "it reads as done to every future scan while nothing was built.",
    ]
    if blocks_so_far >= 1:
        lines += [
            "",
            "(raised %d/%d times for this batch — after %d the turn ends regardless, so "
            "if these are genuinely not worth automating, say so in a `wontfix` row "
            "rather than waiting it out.)" % (blocks_so_far + 1, MAX_BLOCKS, MAX_BLOCKS),
        ]
    return "\n".join(lines)


# ---------------------------------------------------------------------- hook


def decide() -> None:
    if os.environ.get("AUTOMATION_GAP_OFF"):
        sys.stderr.write("[info] automation gate disabled by AUTOMATION_GAP_OFF\n")
        allow()

    payload = read_payload()
    session = str(payload.get("session_id") or payload.get("transcript_path") or "?")
    turn = current_turn(load_transcript(payload.get("transcript_path")))
    commands = shell_commands(turn)
    if not commands:
        allow()  # a turn that ran nothing cannot have done anything by hand

    sightings = Sightings()
    found = candidates_from_commands(commands, sightings, session_id=session, record=True)
    if not found:
        allow()

    backlog = Backlog()
    if backlog.parse_error:
        # A gate that cannot judge must SAY so. It has no exit code a human
        # will see, so stderr is the only place to be honest.
        sys.stderr.write("[warn] automation gate DEAD: backlog %s\n" % backlog.parse_error)
        allow()

    undecided = [c for c in found if not backlog.accounted(c.signature)]
    if not undecided:
        allow()

    blocks, ctx = escalation(session, [c.signature for c in undecided])
    if blocks >= MAX_BLOCKS:
        sys.stderr.write(
            "[warn] automation gate: %d shape(s) still unrecorded after %d asks — "
            "letting the turn end.\n" % (len(undecided), MAX_BLOCKS))
        allow()

    bump(ctx)
    block(render_block(undecided, os.path.relpath(backlog.path, project_dir()), blocks))


# ----------------------------------------------------------------- self-test


def _self_test() -> int:
    failures: List[str] = []

    def check(name: str, cond: bool) -> None:
        if not cond:
            failures.append(name)

    import tempfile

    # signatures fold the variable part, and only that part
    check("container name folded",
          signature_of("docker restart web-1") == signature_of("docker restart web-2"))
    check("verb preserved",
          signature_of("docker restart x") != signature_of("docker ps"))
    check("remote unwrapped and marked",
          signature_of("ssh host 'systemctl restart nginx'") == "ssh:systemctl restart")
    check("leading cd skipped",
          signature_of("cd /srv && docker restart x") == "docker restart")
    check("env assignment stripped",
          signature_of("TAG=1 docker compose build web").startswith("docker compose"))
    check("inline code is not judgeable",
          signature_of("python - <<'PY'\nimport os\nPY") == ""
          and signature_of('python -c "import os"') == "")
    check("loop body carries the verb, not `for`",
          signature_of("for c in a b; do docker restart $c; done") == "loop:docker restart")
    check("command substitution is the command",
          signature_of("for i in 1 2; do s=$(docker ps -a); done") == "loop:docker ps")
    check("a shell variable is not a subcommand",
          signature_of('git "$w" status') == signature_of('git "$other" status')
          == "git status")
    check("a flag's VALUE is not a subcommand",
          signature_of("git -C /some/path status") == "git status")
    check("an inline shell with a combined flag is not judgeable",
          signature_of("bash -lc 'docker restart web'") == "")

    empty = Sightings(os.path.join(tempfile.gettempdir(), "nonexistent-sightings.jsonl"))

    check("AT001 fires", any(c.rule == "AT001" for c in candidates_from_commands(
        ["docker restart a", "docker restart b", "docker restart c"], empty)))
    check("AT001 silent on reads", not any(c.rule == "AT001" for c in candidates_from_commands(
        ["docker ps", "docker ps -a", "docker ps | grep web", "docker ps"], empty)))
    check("AT001 silent on dev flow", not candidates_from_commands(
        ["pytest -x"] * 3 + ["git commit -m a", "git commit -m b", "git commit -m c"], empty))
    check("AT001 silent on existing scripts", not candidates_from_commands(
        ["python tools/check_x.py"] * 4 + ["./deploy.sh"] * 4
        + ["timeout 300 python tools/mint.py 2>&1 | tail -5"] * 4
        + ["python -m mypkg.cli run"] * 4, empty))
    check("inline code raises nothing", not candidates_from_commands(
        ["python - <<'PY'\nprint(1)\nPY"] * 6 + ['python -c "print(2)"'] * 6, empty))
    check("inline code is counted, not silently dropped",
          count_inline_code(["python -c 'x'", "ls"]) == 1)
    check("AT002 fires", any(c.rule == "AT002" for c in candidates_from_commands(
        ["docker stop x && docker rm x && docker run --name x img && systemctl status x"],
        empty)))
    check("AT002 silent on read pipelines", not any(
        c.rule == "AT002" for c in candidates_from_commands(
            ["cat log | grep ERROR | sort | uniq -c | head -20",
             "Get-Service | Where-Object { $_.Status -eq 'Running' } "
             "| Select-Object Name | Format-Table"], empty)))

    with tempfile.TemporaryDirectory() as td:
        s = Sightings(os.path.join(td, "s.jsonl"))
        s.record("docker ps", "docker ps", "session-A")
        check("AT003 fires across sessions", any(
            c.rule == "AT003" for c in candidates_from_commands(
                ["docker ps"], s, session_id="session-B")))
        check("AT003 silent within one session", not any(
            c.rule == "AT003" for c in candidates_from_commands(
                ["docker ps"], s, session_id="session-A")))
        s.record("ls", "ls -la", "session-A")
        s.record("grep", "grep -r x .", "session-A")
        check("AT003 silent on generic shell plumbing", not candidates_from_commands(
            ["ls -la", "grep -r x ."], s, session_id="session-B"))
        check("sightings persist",
              Sightings(os.path.join(td, "s.jsonl")).sessions_for("docker ps", "session-B") == 2)

        bad = os.path.join(td, "backlog.yaml")
        with open(bad, "w", encoding="utf-8") as fh:
            fh.write("version: 1\nentries:\n"
                     "  - signature: 'a b'\n    status: bogus\n"
                     "  - signature: 'c d'\n    status: wontfix\n"
                     "  - signature: 'e f'\n    status: automated\n    target: nope/missing.py\n"
                     "  - signature: 'a b'\n    status: open\n")
        joined = " | ".join(Backlog(bad).check())
        check("AB001 bad status caught", "AB001" in joined)
        check("AB002 reasonless wontfix caught", "AB002" in joined)
        check("AB003 phantom target caught", "AB003" in joined)
        check("AB004 duplicate caught", "AB004" in joined)

        good = os.path.join(td, "clean.yaml")
        with open(good, "w", encoding="utf-8") as fh:
            fh.write("# a comment\nversion: 1\nentries:\n"
                     "  - signature: 'docker restart'\n    status: wontfix\n"
                     "    reason: one-off during an incident\n")
        clean = Backlog(good)
        check("clean backlog passes", not clean.check())
        check("a wontfix row discharges", clean.accounted("docker restart"))
        check("an unrelated shape is not discharged", not clean.accounted("curl"))

        empty_file = os.path.join(td, "empty.yaml")
        with open(empty_file, "w", encoding="utf-8") as fh:
            fh.write("version: 1\nentries: []\n")
        check("an empty backlog parses and decides nothing",
              not Backlog(empty_file).entries and not Backlog(empty_file).parse_error)

        open_only = os.path.join(td, "open.yaml")
        with open(open_only, "w", encoding="utf-8") as fh:
            fh.write("version: 1\nentries:\n  - signature: 'docker restart'\n    status: open\n")
        check("an `open` row does NOT discharge",
              not Backlog(open_only).accounted("docker restart"))

        toil = candidates_from_commands(
            ["docker restart a", "docker restart b", "docker restart c"], empty)
        msg = render_block(toil, "backlog.yaml", 0)
        check("the block names the signature", "docker restart" in msg)
        check("the block offers automated", "status: automated" in msg)
        check("the block offers wontfix", "wontfix" in msg)

    if failures:
        print("SELF-TEST FAILED:")
        for f in failures:
            print("  - %s" % f)
        return 1
    print("SELF-TEST OK — rules fire, false-positive guards hold, "
          "backlog rules fail as designed")
    return 0


# ----------------------------------------------------------------------- cli


def _cli(argv: List[str]) -> int:
    if "--check" in argv:
        backlog = Backlog()
        if backlog.parse_error:
            print("CANNOT JUDGE: %s: %s" % (backlog.path, backlog.parse_error))
            return 2
        problems = backlog.check()
        for p in problems:
            print("VIOLATION %s" % p)
        print("checked %d backlog entries in %s" % (len(backlog.entries), backlog.path))
        return 1 if problems else 0

    # --report: scan a transcript for candidates.
    path = ""
    if "--transcript" in argv:
        path = argv[argv.index("--transcript") + 1]
    else:
        base = os.path.join(os.path.expanduser("~"), ".claude", "projects")
        newest, newest_at = "", 0.0
        for root, _dirs, files in os.walk(base) if os.path.isdir(base) else []:
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                full = os.path.join(root, name)
                try:
                    at = os.path.getmtime(full)
                except OSError:
                    continue
                if at > newest_at:
                    newest, newest_at = full, at
        path = newest
    if not path or not os.path.isfile(path):
        print("CANNOT JUDGE: no transcript found (pass --transcript <path.jsonl>)")
        return 2

    commands: List[str] = []
    for entry in load_transcript(path):
        message = entry.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        for b in content if isinstance(content, list) else []:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            if str(b.get("name", "")).lower() not in {"bash", "powershell", "shell"}:
                continue
            tool_input = b.get("input")
            if isinstance(tool_input, dict):
                for key in ("command", "cmd", "script"):
                    value = tool_input.get(key)
                    if isinstance(value, str) and value.strip():
                        commands.append(value)
                        break
    if not commands:
        print("CANNOT JUDGE: no shell commands in %s" % path)
        return 2

    backlog = Backlog()
    found = candidates_from_commands(commands, Sightings(), session_id=os.path.basename(path))
    print("scanned %d shell commands from %s" % (len(commands), path))
    inline = count_inline_code(commands)
    if inline:
        print("NOTICE %d inline one-off script(s). These raise nothing by design — but if "
              "any is one you have written before, it is a tool that does not exist yet."
              % inline)
    undecided = [c for c in found if not backlog.accounted(c.signature)]
    if not found:
        print("no manual-toil candidates — nothing repeated, chained or recurring")
        return 0
    for c in found:
        mark = " " if backlog.accounted(c.signature) else "!"
        print("%s [%s] %s\n        %s\n        e.g. %s\n        lane: %s\n"
              % (mark, c.rule, c.signature, c.why, c.sample[:140], c.lane()))
    return 1 if undecided else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    if len(sys.argv) > 1:
        sys.exit(_cli(sys.argv[1:]))
    try:
        decide()
    except SystemExit:
        raise
    except Exception as exc:  # never break a session over a gate
        sys.stderr.write("[warn] stop_automation_gap: %s\n" % exc)
    allow()
