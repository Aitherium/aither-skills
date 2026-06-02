#!/usr/bin/env python3
"""Pre-publish leak guard — inspect a built Python distribution (wheel or sdist)
*before* it ships to a public index, and fail (non-zero exit) if it bundles
files or imports you meant to keep private: proprietary modules, secrets,
premium configs, internal namespaces.

Nothing here is project-specific — every rule is a flag (or a config file), so
this is a drop-in CI gate for any open-core package.

Rules
-----
  --forbid-path GLOB    Member must NOT exist. Glob matches the full archive
                        path OR the basename (so `nanogpt.py` and
                        `*/nanogpt.py` both work). Repeatable.
  --forbid-import NAME   No `.py` member may `import NAME` / `from NAME ...`.
                        Repeatable.
  --require-file GLOB    At least one member MUST match (e.g. a licensing
                        keystone). Repeatable.
  --allow-path GLOB      Exception: a member matching this is never a violation,
                        even if a --forbid-path would catch it. Repeatable.

Examples
--------
    # newest wheel in dist/ must not bundle nanogpt.py or import an internal pkg
    python check_package_leaks.py \
        --forbid-path '*/nanogpt.py' --forbid-import mycorp_internal

    # only the free identity may ship; a licensing module must be present
    python check_package_leaks.py dist/mypkg-2.0.0-py3-none-any.whl \
        --forbid-path '*/identities/*.yaml' \
        --allow-path  '*/identities/free.yaml' \
        --require-file '*/licensing.py'

    # load the same rules from a config file (JSON, or TOML on py3.11+)
    python check_package_leaks.py --config .leakguard.toml

Config file keys mirror the flags: forbid_path[], forbid_import[],
require_file[], allow_path[], dist_dir.

Exit codes: 0 = clean, 1 = violations found, 2 = no distribution found / bad input.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
import tarfile
import zipfile
from pathlib import Path


def _norm(name: str) -> str:
    """Normalize an archive member name to forward slashes."""
    return name.replace("\\", "/")


def _matches(name: str, pattern: str) -> bool:
    """True if `pattern` matches the full path or just the basename."""
    name = _norm(name)
    return fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(name.rsplit("/", 1)[-1], pattern)


def _iter_members(dist: Path):
    """Yield (member_name, read_bytes_callable) for a wheel/zip or sdist tarball."""
    suffix = dist.name.lower()
    if suffix.endswith((".whl", ".zip", ".egg")):
        with zipfile.ZipFile(dist) as zf:
            for name in zf.namelist():
                if name.endswith("/"):
                    continue
                yield name, (lambda n=name: zf.read(n))
    elif suffix.endswith((".tar.gz", ".tgz", ".tar")):
        mode = "r:gz" if suffix.endswith((".tar.gz", ".tgz")) else "r:"
        with tarfile.open(dist, mode) as tf:
            for member in tf.getmembers():
                if not member.isfile():
                    continue
                yield member.name, (lambda m=member: tf.extractfile(m).read())
    else:
        raise ValueError(f"unsupported distribution type: {dist.name}")


def _newest_dist(dist_dir: Path) -> Path | None:
    if not dist_dir.is_dir():
        return None
    candidates = [
        p for ext in ("*.whl", "*.tar.gz", "*.tgz", "*.zip")
        for p in dist_dir.glob(ext)
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def _load_config(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() in (".toml",):
        try:
            import tomllib  # py3.11+
        except ModuleNotFoundError:  # pragma: no cover
            print("ERROR: TOML config needs Python 3.11+ (or use JSON).", file=sys.stderr)
            raise SystemExit(2)
        return tomllib.loads(text)
    return json.loads(text)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Fail a build if a Python distribution leaks private files/imports.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("dist", nargs="?", help="wheel/sdist to inspect (default: newest in --dist-dir)")
    p.add_argument("--dist-dir", default="dist", help="where to look for the newest dist (default: dist)")
    p.add_argument("--forbid-path", action="append", default=[], metavar="GLOB",
                   help="member that must NOT ship (repeatable)")
    p.add_argument("--forbid-import", action="append", default=[], metavar="NAME",
                   help="module no .py source may import (repeatable)")
    p.add_argument("--require-file", action="append", default=[], metavar="GLOB",
                   help="member that MUST ship, e.g. a licensing keystone (repeatable)")
    p.add_argument("--allow-path", action="append", default=[], metavar="GLOB",
                   help="exception to --forbid-path (repeatable)")
    p.add_argument("--config", metavar="FILE", help="load rules from JSON/TOML")
    return p


def run(args: argparse.Namespace) -> int:
    forbid_path = list(args.forbid_path)
    forbid_import = list(args.forbid_import)
    require_file = list(args.require_file)
    allow_path = list(args.allow_path)
    dist_dir = args.dist_dir

    if args.config:
        cfg = _load_config(Path(args.config))
        forbid_path += cfg.get("forbid_path", [])
        forbid_import += cfg.get("forbid_import", [])
        require_file += cfg.get("require_file", [])
        allow_path += cfg.get("allow_path", [])
        dist_dir = cfg.get("dist_dir", dist_dir)

    if not (forbid_path or forbid_import or require_file):
        print("ERROR: no rules given. Pass --forbid-path/--forbid-import/--require-file "
              "or --config.", file=sys.stderr)
        return 2

    dist = Path(args.dist) if args.dist else _newest_dist(Path(dist_dir))
    if not dist or not dist.is_file():
        print(f"ERROR: no distribution found (looked in '{dist_dir}/'). Build first: "
              f"python -m build", file=sys.stderr)
        return 2

    print(f"LEAK GUARD: inspecting {dist.name}")
    import_re = {
        name: re.compile(
            rb"^\s*(from|import)\s+" + re.escape(name).encode() + rb"(\.|\s|$)",
            re.MULTILINE,
        )
        for name in forbid_import
    }

    violations: list[str] = []
    required_hit = {pat: False for pat in require_file}

    for name, read in _iter_members(dist):
        allowed = any(_matches(name, a) for a in allow_path)

        if not allowed:
            for pat in forbid_path:
                if _matches(name, pat):
                    violations.append(f"LEAK: forbidden file shipped: {name}  (matched '{pat}')")

        for pat in require_file:
            if _matches(name, pat):
                required_hit[pat] = True

        if import_re and name.endswith(".py") and not allowed:
            data = read()
            for mod, rx in import_re.items():
                if rx.search(data):
                    violations.append(f"LEAK: imports forbidden module '{mod}': {name}")

    for pat, hit in required_hit.items():
        if not hit:
            violations.append(f"MISSING: required file not in distribution: '{pat}'")

    if violations:
        print("LEAK GUARD FAILED:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    print("LEAK GUARD PASSED: no forbidden files/imports, all required files present.")
    return 0


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
