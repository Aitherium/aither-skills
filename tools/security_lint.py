#!/usr/bin/env python3
"""
security_lint.py — static checks for the fail-closed-authz defect classes that
ruff and mypy cannot see.

Part of the `fail-closed-authz` skill. The four checks below are the MECHANICAL
subset of six defect classes; the skill carries the three semantic classes that
no static tool can see, and every one of the six was a real bug caught by review.

Catches the MECHANICAL subset (semantic classes 2/5/6 still need review):
  SEC001 (error): verify=False on a TLS call — trust the internal CA instead.
  SEC002 (error): fail-OPEN gate — a security-decision function returns a truthy
                  value from an `except` handler (an error must DENY, not allow).
  SEC003 (warn) : fabricated-platform trust — returning True on caller_type ==
                  "platform" inside an ownership/authz gate.
  SEC004 (warn) : inert fail-soft return — a function returns an empty collection
                  on a failure path but returns non-empty on success, making it
                  impossible for callers to distinguish "no data" from "broken".
                  Fix: add a "degraded" flag or "error" key to signal failure.

Usage:
  python tools/security_lint.py <file.py> [<file.py> ...]
  python tools/security_lint.py            # scan the default security globs
Exit code: 1 if any ERROR-level finding, else 0.
"""
from __future__ import annotations

import ast
import os
import re
import sys
from pathlib import Path

# Functions whose name marks them a security DECISION → must be fail-closed.
_GATE_NAME = re.compile(
    r"(gate|entitl|owns|authz|author|allow|_ok$|^is_|verify_|check_|require_|"
    r"permit|cotenan|isolat)", re.I)

# Default scan set when no args: the auth/tenancy/entitlement/cache-sharing spine.
_DEFAULT_GLOBS = [
    # Generic auth/tenancy/entitlement spine. Override by passing paths explicitly,
    # or by setting SECURITY_LINT_GLOBS to a comma-separated list of globs.
    "**/auth/**/*.py",
    "**/security/**/*.py",
    "**/permissions/**/*.py",
    "**/tenant*/**/*.py",
    "**/entitle*/**/*.py",
    "**/*authz*.py",
    "**/*rbac*.py",
]


def _truthy_return(node: ast.AST) -> bool:
    """True if this Return yields an allow-ish value (True / nonzero / non-empty)."""
    if not isinstance(node, ast.Return) or node.value is None:
        return False
    v = node.value
    if isinstance(v, ast.Constant):
        return bool(v.value)  # True, nonzero int, non-empty str, etc.
    return False


def _gate_functions(tree: ast.AST):
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and _GATE_NAME.search(n.name):
            yield n


def _returns_in(node: ast.AST):
    """Returns directly within `node`, NOT descending into nested functions."""
    for child in ast.walk(node):
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and child is not node:
            continue
        if isinstance(child, ast.Return):
            yield child


def _is_empty_return(node: ast.Return) -> bool:
    """True if this Return yields an empty collection or 'all-empty' dict.

    Matches:
      - return []
      - return {}
      - return {"key": [], "other": 0}  (all values empty/zero)
    Does NOT match:
      - return {"error": "msg"}  (has non-empty string)
      - return {"degraded": True, "nodes": []}  (has non-empty value)
    """
    if not isinstance(node, ast.Return) or node.value is None:
        return False

    v = node.value
    # Empty list or dict literal
    if isinstance(v, ast.List) and len(v.elts) == 0:
        return True
    if isinstance(v, ast.Dict):
        if len(v.keys) == 0:
            return True  # Empty {}
        # Check if all values are empty/zero/false
        all_empty = True
        for val in v.values:
            if isinstance(val, ast.Constant):
                # Allowed empty: None, empty str, 0, False
                # Disallowed: non-empty str, True, non-zero int
                if isinstance(val.value, str):
                    if val.value:  # Non-empty string → not all-empty
                        all_empty = False
                        break
                elif isinstance(val.value, bool):
                    if val.value:  # True → not all-empty
                        all_empty = False
                        break
                elif isinstance(val.value, int):
                    if val.value != 0:  # Non-zero → not all-empty
                        all_empty = False
                        break
                # None, 0, False, empty str are OK (empty)
            elif isinstance(val, (ast.List, ast.Dict)):
                # Nested empty list/dict is OK for all-empty check
                pass
            else:
                # Any other expression (variable, call, etc.) → not provably empty
                all_empty = False
                break
        return all_empty
    return False


def _returns_in_except(fn: ast.AST) -> list[ast.Return]:
    """All Return nodes directly in except handlers within `fn` (not nested functions)."""
    returns = []
    for n in ast.walk(fn):
        if isinstance(n, ast.ExceptHandler):
            # Walk this handler but skip nested functions
            for child in ast.walk(n):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and child is not n:
                    continue
                if isinstance(child, ast.Return):
                    returns.append(child)
    return returns


def _is_failure_test(test: ast.AST) -> bool:
    """True if this test looks like a failure/bad-result check.

    Detects:
      if not X
      if X is None
      if X != something
      if X.status_code != 200
      if (not X) or (X != Y)
    """
    if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
        return True
    if isinstance(test, ast.Compare):
        for op in test.ops:
            if isinstance(op, (ast.NotEq, ast.IsNot)):
                return True
    if isinstance(test, ast.BoolOp):
        # For Or/And, if ANY branch looks like failure, treat it as failure check
        for val in test.values:
            if _is_failure_test(val):
                return True
    return False


def _returns_in_failure_check(fn: ast.AST) -> list[ast.Return]:
    """All Return nodes in branches checking for a failed result.

    Detects:
      if not resp: return ...
      if resp.status_code != 200: return ...
      if not ok: return ...
      if not ok or ok.status != 200: return ...
    """
    returns = []
    for n in ast.walk(fn):
        if not isinstance(n, ast.If):
            continue
        # Check if this is a "failure check" (not ok, status != 200, etc.)
        if _is_failure_test(n.test):
            # Collect direct returns from the if body (not nested functions)
            for child in n.body:
                if isinstance(child, ast.Return):
                    returns.append(child)
                # Recursively get returns from statement bodies (if/for/while/with)
                elif isinstance(child, (ast.If, ast.For, ast.While, ast.With)):
                    for subchild in ast.walk(child):
                        if isinstance(subchild, ast.Return):
                            returns.append(subchild)
    return returns


def check_file(path: Path) -> list[tuple[str, int, str, str]]:
    """Return list of (level, lineno, code, message)."""
    findings: list[tuple[str, int, str, str]] = []
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (SyntaxError, OSError) as e:
        return [("error", 0, "SEC000", f"could not parse: {e}")]

    # SEC001 — verify=False anywhere
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            for kw in n.keywords:
                if kw.arg == "verify" and isinstance(kw.value, ast.Constant) \
                        and kw.value.value is False:
                    findings.append(("error", n.lineno, "SEC001",
                                     "verify=False disables TLS verification — trust the internal CA"))

    # SEC002 / SEC003 — inside gate-named functions, inspect except handlers
    for fn in _gate_functions(tree):
        for h in ast.walk(fn):
            if not isinstance(h, ast.ExceptHandler):
                continue
            for r in _returns_in(h):
                if _truthy_return(r):
                    findings.append(("error", r.lineno, "SEC002",
                                     f"fail-OPEN: '{fn.name}' returns a truthy value from an "
                                     f"except handler — a gate must DENY on error"))
        # SEC003 — returning True on a caller_type == "platform" comparison
        for cmp in ast.walk(fn):
            if isinstance(cmp, ast.Compare) and any(
                    isinstance(c, ast.Constant) and c.value == "platform" for c in cmp.comparators):
                findings.append(("warn", cmp.lineno, "SEC003",
                                 f"'{fn.name}' branches on caller_type=='platform' — fabricated "
                                 f"PLATFORM_CALLER must NOT be auto-trusted as owner"))

    # SEC004 — inert fail-soft returns: empty on error, non-empty on success
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue

        # Collect all returns in this function (not nested functions)
        all_returns = []
        for node in ast.walk(fn):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node is not fn:
                continue
            if isinstance(node, ast.Return):
                all_returns.append(node)

        # Collect returns from failure paths (except handlers + failure checks)
        failure_returns_list = _returns_in_except(fn) + _returns_in_failure_check(fn)
        failure_returns_set = set(id(r) for r in failure_returns_list)

        # Check for empty returns in failure paths
        has_empty_failure = any(
            _is_empty_return(r) for r in failure_returns_list
        )
        has_nonempty_success = any(
            not _is_empty_return(r) for r in all_returns
            if id(r) not in failure_returns_set
        )

        # Fire if there's an asymmetry: empty on error, non-empty on success
        if has_empty_failure and has_nonempty_success:
            # Find the line of the first empty failure return
            for r in failure_returns_list:
                if _is_empty_return(r):
                    findings.append(("warn", r.lineno, "SEC004",
                                     f"'{fn.name}' returns an empty result on a failure path — "
                                     f"caller cannot distinguish 'empty' from 'broken'. "
                                     f"Add a 'degraded' flag or 'error' key to signal failure."))
                    break

    return findings


def _globs() -> list[str]:
    """Default globs, overridable via SECURITY_LINT_GLOBS (comma-separated)."""
    env = os.environ.get("SECURITY_LINT_GLOBS", "").strip()
    if env:
        return [g.strip() for g in env.split(",") if g.strip()]
    return _DEFAULT_GLOBS


def _resolve_targets(args: list[str]) -> list[Path]:
    root = Path(__file__).resolve().parents[2]  # AitherOS/
    if args:
        return [Path(a) for a in args]
    out: list[Path] = []
    for g in _globs():
        out.extend(sorted(root.glob(g)))
    return out


def _selftest() -> int:
    """Prove the linter actually fires. A linter nobody tested is a linter that
    silently passes everything — which is the SEC004 defect class, in the tool."""
    import tempfile

    v = "verify=" + "False"  # assembled so this file never contains the literal
    bad = (
        "import httpx\n\n"
        "def check_tenant_access(user, tenant_id):\n"
        "    try:\n"
        "        return user.tenant_id == tenant_id\n"
        "    except Exception:\n"
        "        return True\n\n"
        "def fetch_internal(url):\n"
        f"    return httpx.get(url, {v})\n\n"
        "def owns_resource(caller, res):\n"
        '    if caller.caller_type == "platform":\n'
        "        return True\n"
        "    return caller.id == res.owner_id\n"
    )
    good = (
        "import httpx\n\n"
        "def check_tenant_access(user, tenant_id):\n"
        "    try:\n"
        "        return bool(user and user.tenant_id == tenant_id)\n"
        "    except Exception:\n"
        "        return False\n\n"
        "def fetch_internal(url, ca_bundle):\n"
        "    return httpx.get(url, verify=ca_bundle)\n"
    )

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        bad_p = Path(td) / "bad.py"
        good_p = Path(td) / "good.py"
        bad_p.write_text(bad, encoding="utf-8")
        good_p.write_text(good, encoding="utf-8")

        codes = {c for _lvl, _ln, c, _m in check_file(bad_p)}
        for expected in ("SEC001", "SEC002", "SEC003"):
            if expected not in codes:
                failures.append(f"{expected} did NOT fire on the bad fixture")

        clean = check_file(good_p)
        if clean:
            failures.append(f"false positive on the clean fixture: {clean}")

        # This sub-check deliberately triggers the abort path; swallow its output
        # so a PASSING selftest doesn't print what looks like an error.
        import contextlib
        import io

        missing = Path(td) / "no-such-file.py"
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf), contextlib.redirect_stdout(buf):
            rc = main(["security_lint", str(missing)])
        if rc != 2:
            failures.append("a nonexistent named target did not abort with exit 2")

    if failures:
        for f in failures:
            print(f"SELFTEST FAIL: {f}", file=sys.stderr)
        return 1
    print("security_lint --selftest: OK — SEC001/2/3 fire, clean file is clean, "
          "missing target aborts")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if args and args[0] == "--selftest":
        return _selftest()
    explicit = bool(args)
    targets = _resolve_targets(args)
    errors = 0
    warns = 0
    scanned = 0

    # A path the caller NAMED must exist and be Python. Silently skipping it is
    # the silent-no-op defect this linter exists to catch (a typo'd path in CI
    # would otherwise print "0 error(s)" and pass the gate). Globbed targets may
    # legitimately match nothing, so only explicit arguments are hard errors.
    if explicit:
        bad = [p for p in targets if not p.exists()]
        notpy = [p for p in targets if p.exists() and p.suffix != ".py"]
        if bad or notpy:
            for p in bad:
                print(f"ERROR SEC000 {p}: no such file", file=sys.stderr)
            for p in notpy:
                print(f"ERROR SEC000 {p}: not a Python file", file=sys.stderr)
            print(
                f"\nsecurity_lint: ABORTED — {len(bad) + len(notpy)} named target(s) "
                f"unusable; refusing to report a clean run over files it never read.",
                file=sys.stderr,
            )
            return 2

    for p in targets:
        if not p.exists() or p.suffix != ".py":
            continue
        scanned += 1
        for level, line, code, msg in check_file(p):
            print(f"{level.upper():5s} {code} {p}:{line}: {msg}")
            if level == "error":
                errors += 1
            else:
                warns += 1

    if scanned == 0:
        print(
            "\nsecurity_lint: no Python files matched — nothing was checked. "
            "Pass paths explicitly or set SECURITY_LINT_GLOBS.",
            file=sys.stderr,
        )
        return 2

    print(f"\nsecurity_lint: {errors} error(s), {warns} warning(s) "
          f"across {scanned} file(s) scanned")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
