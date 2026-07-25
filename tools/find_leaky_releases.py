#!/usr/bin/env python3
"""Find (and prove) published releases on a package index that leak private code.

Use this after you discover that early versions of an open-core package shipped
something they shouldn't have (a proprietary module, an internal namespace, a
premium config). It lists the suspect versions and — with --verify — downloads
each wheel and applies your leak rules to *prove* the leak before you yank.

Package indexes deliberately have no API/CLI for yank/delete (it's an
authenticated, irreversible owner action), so this tool stops at producing the
exact list + the "Manage" URL + a checklist for the human to action.

Examples
--------
    # list every version below 2.0.0 (assumed leaky)
    python find_leaky_releases.py mypkg --cutoff 2.0.0

    # download wheels and only report versions that ACTUALLY bundle the leak
    python find_leaky_releases.py mypkg --verify \
        --forbid-path '*/nanogpt.py' --forbid-path 'mycorp_internal/*'

    # combine: pre-cutoff AND proven
    python find_leaky_releases.py mypkg --cutoff 2.0.0 --verify \
        --forbid-path '*/secrets.py' --allow-path '*/secrets_example.py'

Rules (--forbid-path / --allow-path) match the full archive path OR the
basename, same as check_package_leaks.py.

Exit codes: 0 = ran successfully (leaky list printed), 2 = network/index error.
"""

from __future__ import annotations

import argparse
import fnmatch
import io
import json
import sys
import urllib.request
import zipfile


def _norm(name: str) -> str:
    return name.replace("\\", "/")


def _matches(name: str, pattern: str) -> bool:
    name = _norm(name)
    return fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(name.rsplit("/", 1)[-1], pattern)


def _version_tuple(v: str) -> tuple:
    """Best-effort PEP 440-ish ordering (strips pre/post/dev markers to 0s)."""
    out = []
    for chunk in v.replace("a", ".").replace("b", ".").replace("rc", ".").replace("+", ".").split("."):
        out.append(int(chunk) if chunk.isdigit() else 0)
    return tuple(out)


def _fetch_releases(project: str, index_json: str) -> dict:
    url = f"{index_json.rstrip('/')}/{project}/json"
    with urllib.request.urlopen(url, timeout=20) as resp:  # noqa: S310 (trusted index)
        return json.load(resp)["releases"]


def _wheel_leaks(url: str, forbid_path: list[str], allow_path: list[str]) -> list[str]:
    with urllib.request.urlopen(url, timeout=90) as resp:  # noqa: S310
        blob = resp.read()
    leaks: list[str] = []
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        for name in zf.namelist():
            if name.endswith("/"):
                continue
            if any(_matches(name, a) for a in allow_path):
                continue
            for pat in forbid_path:
                if _matches(name, pat):
                    leaks.append(f"{name} (matched '{pat}')")
    return sorted(set(leaks))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="List/prove published package versions that leak private code.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("project", help="package name on the index (e.g. requests)")
    p.add_argument("--cutoff", metavar="X.Y.Z",
                   help="versions strictly below this are flagged (omit to consider all)")
    p.add_argument("--verify", action="store_true",
                   help="download each candidate wheel and prove the leak with --forbid-path")
    p.add_argument("--forbid-path", action="append", default=[], metavar="GLOB",
                   help="leak pattern to prove under --verify (repeatable)")
    p.add_argument("--allow-path", action="append", default=[], metavar="GLOB",
                   help="exception to --forbid-path (repeatable)")
    p.add_argument("--index-json", default="https://pypi.org/pypi",
                   help="JSON API base (default: https://pypi.org/pypi)")
    p.add_argument("--manage-url", default="https://pypi.org/manage/project/{project}/releases/",
                   help="owner 'manage releases' URL template ({project} is substituted)")
    return p


def run(args: argparse.Namespace) -> int:
    try:
        releases = _fetch_releases(args.project, args.index_json)
    except Exception as exc:  # noqa: BLE001 — surface any network/index failure cleanly
        print(f"ERROR: could not fetch releases for '{args.project}': {exc}", file=sys.stderr)
        return 2

    cutoff = _version_tuple(args.cutoff) if args.cutoff else None
    candidates = sorted(
        (v for v in releases if cutoff is None or _version_tuple(v) < cutoff),
        key=_version_tuple,
    )

    scope = f"below {args.cutoff}" if args.cutoff else "all versions (no cutoff)"
    print(f"{args.project}: {len(releases)} published versions; {len(candidates)} candidate(s) "
          f"({scope}).\n")

    leaky = candidates
    if args.verify:
        if not args.forbid_path:
            print("ERROR: --verify needs at least one --forbid-path to prove.", file=sys.stderr)
            return 2
        print("Verifying (downloading wheels)…\n")
        proven: list[str] = []
        for v in candidates:
            wheel = next((f for f in releases[v] if f["filename"].endswith(".whl")), None)
            if not wheel:
                print(f"  {v}: (no wheel — sdist only, not verified)")
                continue
            try:
                hits = _wheel_leaks(wheel["url"], args.forbid_path, args.allow_path)
            except Exception as exc:  # noqa: BLE001
                print(f"  {v}: <download failed: {exc}>")
                continue
            if hits:
                proven.append(v)
                print(f"  {v}: LEAKS — {', '.join(hits)}")
            else:
                print(f"  {v}: clean")
        leaky = proven
        print()

    if not leaky:
        print("No leaky versions identified. Nothing to yank. ✅")
        return 0

    manage = args.manage_url.format(project=args.project)
    print("LEAKY VERSIONS TO YANK/DELETE:")
    print("  " + ", ".join(leaky))
    print()
    print("HOW TO REMOVE (owner action — requires index login + 2FA):")
    print(f"  1. Open {manage}")
    print("  2. For each version: prefer 'Yank' — keeps existing pinned installs")
    print("     working but hides the version from new dependency resolves. Reason e.g.:")
    print("     'Leaks private modules; superseded by a clean release.'")
    print("  3. Use 'Delete' only if legally required — it breaks pinned installs and")
    print("     the version number can never be reused.")
    print()
    print("  Note: indexes provide no API/CLI for this; it must be done in the web UI.")
    return 0


def main(argv: list[str]) -> int:
    return run(build_parser().parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
