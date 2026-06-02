#!/usr/bin/env python3
"""Verify a Python package's __all__ exports, version sync, and orphan modules.

Generic validator for any Python package. Catches three categories of issues:

  1. **Ghost exports**: __all__ entries that reference non-existent modules,
     unresolvable via eager import or __getattr__ fallback.
  2. **Version mismatch**: __version__ string in __init__.py disagrees with
     the version in pyproject.toml.
  3. **Orphan modules**: Top-level .py files with zero imports from anywhere
     (dead code; disable with --no-orphan-check if your package uses plugins).

Auto-detection
--------------
If --package is omitted and exactly one top-level directory contains both
__init__.py and a sibling pyproject.toml, that directory is used. Otherwise
--package is required.

Default scan includes the package dir plus siblings: tests/, examples/,
scripts/ (if they exist). Use --scan-dir to add more.

Examples
--------
    # Auto-detect package, use default scans
    python check_exports.py

    # Explicit package and pyproject
    python check_exports.py --package mylib --pyproject ./pyproject.toml

    # Skip orphan check (for plugin-style packages)
    python check_exports.py --no-orphan-check

    # Add extra scan dir (e.g., for monorepo test suites)
    python check_exports.py --scan-dir ../shared/tests --scan-dir ./dev/fixtures

Exit codes: 0 = clean, 1 = issues found, 2 = package/pyproject not found or bad input.
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path


def _detect_package(pyproject_dir: Path) -> Path | None:
    """Auto-detect the package dir if exactly one top-level dir has __init__.py.

    Looks for a sibling of pyproject.toml that contains __init__.py.
    Returns the package dir, or None if auto-detection is ambiguous.
    """
    candidates = []
    for item in pyproject_dir.iterdir():
        if item.is_dir() and (item / "__init__.py").is_file():
            candidates.append(item)

    if len(candidates) == 1:
        return candidates[0]
    return None


def _get_package_name(package_dir: Path) -> str:
    """Derive the import name from the package directory basename."""
    return package_dir.name


def _check_ghost_exports(package_dir: Path, package_name: str) -> list[str]:
    """Check that all __all__ entries resolve via import or __getattr__."""
    errors = []
    init = package_dir / "__init__.py"

    if not init.is_file():
        errors.append(f"__init__.py not found in {package_dir}")
        return errors

    tree = ast.parse(init.read_text(encoding="utf-8"))

    # Collect __all__ names
    all_names: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "__all__":
                    if isinstance(node.value, ast.List):
                        for elt in node.value.elts:
                            if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                                all_names.append(elt.value)

    # Collect lazy import targets from __getattr__
    lazy_names: set[str] = set()
    eager_names: set[str] = set()

    for node in ast.walk(tree):
        # Eager imports at module level (from pkg.X import Y)
        if isinstance(node, ast.ImportFrom) and node.col_offset == 0:
            for alias in node.names:
                eager_names.add(alias.asname or alias.name)

        # __getattr__ function: find all `if name == "X"` comparisons
        if isinstance(node, ast.FunctionDef) and node.name == "__getattr__":
            for child in ast.walk(node):
                if isinstance(child, ast.Compare):
                    for comp in child.comparators:
                        if isinstance(comp, ast.Constant) and isinstance(comp.value, str):
                            lazy_names.add(comp.value)

    resolvable = eager_names | lazy_names
    for name in all_names:
        if name not in resolvable:
            errors.append(
                f"ghost export: '{name}' is in __all__ but has no import or __getattr__ entry"
            )

    return errors


def _check_version_sync(package_dir: Path, pyproject: Path) -> list[str]:
    """Check that __version__ in __init__.py matches pyproject.toml."""
    errors = []
    init = package_dir / "__init__.py"

    if not init.is_file():
        return errors  # Already reported by _check_ghost_exports

    init_version = None
    for line in init.read_text(encoding="utf-8").splitlines():
        if line.startswith("__version__"):
            init_version = line.split("=", 1)[1].strip().strip('"').strip("'")
            break

    if not pyproject.is_file():
        errors.append(f"pyproject.toml not found at {pyproject}")
        return errors

    m = re.search(r'^version\s*=\s*"([^"]+)"', pyproject.read_text(encoding="utf-8"), re.M)
    pyproject_version = m.group(1) if m else None

    if init_version != pyproject_version:
        errors.append(
            f"version mismatch: __init__.py={init_version} vs pyproject.toml={pyproject_version}"
        )

    return errors


def _check_orphan_modules(
    package_dir: Path,
    package_name: str,
    pyproject: Path,
    scan_dirs: list[Path],
    skip_orphan_check: bool,
) -> list[str]:
    """Check for top-level .py modules with zero imports from anywhere."""
    errors = []

    if skip_orphan_check:
        return errors

    # Get all top-level .py files in package/ (excluding __init__.py)
    module_files = {
        f.stem: f for f in package_dir.glob("*.py")
        if f.name != "__init__.py"
    }

    # Collect all .py files to scan for imports
    all_py: list[Path] = []

    # Package dir (all .py files recursively)
    all_py.extend(package_dir.rglob("*.py"))

    # Scan directories
    for scan_dir in scan_dirs:
        if scan_dir.exists():
            all_py.extend(scan_dir.rglob("*.py"))

    # Imported module names
    imported: set[str] = set()

    for py_file in all_py:
        try:
            source = py_file.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        try:
            tree = ast.parse(source)
        except SyntaxError:
            continue

        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                # from pkg.foo import ... or from .foo import ...
                parts = node.module.split(".")
                if len(parts) >= 2 and parts[0] == package_name:
                    imported.add(parts[1])
                elif parts == [package_name]:
                    # from pkg import foo — the imported name is the module
                    for alias in node.names:
                        imported.add(alias.name)
                elif node.level and len(parts) >= 1:
                    imported.add(parts[0])
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    parts = alias.name.split(".")
                    if len(parts) >= 2 and parts[0] == package_name:
                        imported.add(parts[1])

    # Also count __init__.py lazy imports as "used", including __getattr__ entries
    init_source = (package_dir / "__init__.py").read_text(encoding="utf-8")
    init_tree = ast.parse(init_source)
    for node in ast.walk(init_tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            parts = node.module.split(".")
            if len(parts) >= 2 and parts[0] == package_name:
                imported.add(parts[1])

    # Also mark modules referenced in __getattr__ as "used"
    for node in ast.walk(init_tree):
        if isinstance(node, ast.FunctionDef) and node.name == "__getattr__":
            for child in ast.walk(node):
                if isinstance(child, ast.Compare):
                    for comp in child.comparators:
                        if isinstance(comp, ast.Constant) and isinstance(comp.value, str):
                            imported.add(comp.value)

    # Entry points from pyproject.toml count as used
    if pyproject.is_file():
        for m in re.finditer(
            rf'=\s*"({re.escape(package_name)}\.\w+):',
            pyproject.read_text(encoding="utf-8"),
        ):
            parts = m.group(1).split(".")
            if len(parts) >= 2:
                imported.add(parts[1])

    for name, path in sorted(module_files.items()):
        if name not in imported:
            errors.append(f"orphan module: {package_name}/{name}.py is never imported")

    return errors


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Verify a Python package's __all__ exports, version, and orphan modules.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--package",
        type=Path,
        help="package directory (must contain __init__.py). "
        "If omitted, auto-detect if exactly one exists as a sibling of pyproject.toml.",
    )
    p.add_argument(
        "--pyproject",
        type=Path,
        default=Path("pyproject.toml"),
        help="path to pyproject.toml (default: ./pyproject.toml)",
    )
    p.add_argument(
        "--scan-dir",
        action="append",
        dest="scan_dirs",
        type=Path,
        default=[],
        help="extra directory to scan for imports (repeatable; "
        "defaults to package + tests/, examples/, scripts/ if they exist)",
    )
    p.add_argument(
        "--no-orphan-check",
        action="store_true",
        help="skip orphan module check (for plugin-style packages)",
    )
    return p


def run(args: argparse.Namespace) -> int:
    """Run all checks and return exit code."""
    # Resolve package directory
    pyproject = args.pyproject.resolve()
    pyproject_dir = pyproject.parent

    if not pyproject.is_file():
        print(f"ERROR: pyproject.toml not found at {pyproject}", file=sys.stderr)
        return 2

    package_dir = args.package
    if not package_dir:
        package_dir = _detect_package(pyproject_dir)
        if not package_dir:
            print(
                f"ERROR: --package required (no auto-detection: "
                f"zero or multiple top-level dirs with __init__.py in {pyproject_dir})",
                file=sys.stderr,
            )
            return 2
    else:
        package_dir = package_dir.resolve()

    if not package_dir.is_dir():
        print(f"ERROR: package directory not found: {package_dir}", file=sys.stderr)
        return 2

    if not (package_dir / "__init__.py").is_file():
        print(f"ERROR: __init__.py not found in {package_dir}", file=sys.stderr)
        return 2

    package_name = _get_package_name(package_dir)

    # Resolve scan directories
    scan_dirs = [package_dir]
    for pattern in ["tests", "examples", "scripts"]:
        candidate = pyproject_dir / pattern
        if candidate.exists():
            scan_dirs.append(candidate)
    scan_dirs.extend(args.scan_dirs)

    # Run checks
    all_errors: list[str] = []
    all_errors.extend(_check_ghost_exports(package_dir, package_name))
    all_errors.extend(_check_version_sync(package_dir, pyproject))
    all_errors.extend(
        _check_orphan_modules(
            package_dir,
            package_name,
            pyproject,
            scan_dirs,
            args.no_orphan_check,
        )
    )

    # Report
    if all_errors:
        print(f"FAIL: {len(all_errors)} issue(s) found:\n", file=sys.stderr)
        for e in all_errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    else:
        print("OK: all exports resolve, version synced, no orphan modules")
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
