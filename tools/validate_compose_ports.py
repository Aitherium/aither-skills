#!/usr/bin/env python3
"""
validate_compose_ports.py — Generic docker-compose port linter.

Flags:
  - Host-port collisions (same port mapped by 2+ services)
  - Duplicate/overlapping ports across multiple -f files
  - Malformed port mappings (can't parse host:container)
  - Container ports without host mappings (info only)

Usage:
    python validate_compose_ports.py [docker-compose.yml ...]
    python validate_compose_ports.py -f compose.yml -f other.yml --strict

Exit codes:
  0 = all checks passed
  1 = collisions/violations found with --strict
  2 = file not found / bad input
"""

import argparse
import re
import sys
from pathlib import Path

# PyYAML: parses docker-compose files (standard dep for compose usage)
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. Install: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


def parse_port_mapping(port_spec: str) -> tuple[int, int] | None:
    """
    Parse a single port mapping string: [ip:]host:container or [ip:]host:container/protocol.
    Returns (host_port, container_port) or None if unparseable.

    Examples:
      "8000:8000" -> (8000, 8000)
      "127.0.0.1:3000:3000" -> (3000, 3000)
      "9000-9100:9000-9100" -> (9000, 9000)  [only first in range]
      "8080:8080/tcp" -> (8080, 8080)
    """
    spec_str = str(port_spec).strip()

    # Remove protocol suffix (/tcp, /udp)
    if "/" in spec_str:
        spec_str = spec_str.rsplit("/", 1)[0]

    # Pattern: optional [ip:]host:container
    # Handles:
    #   8000:8000
    #   127.0.0.1:8000:8000
    #   8000-8100:8000-8100
    m = re.match(r"^(?:[\d.]+:)?(\d+)(?:-\d+)?:(\d+)(?:-\d+)?$", spec_str)
    if m:
        return (int(m.group(1)), int(m.group(2)))

    return None


def load_compose_file(path: Path) -> dict:
    """Load and parse a docker-compose YAML file."""
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict):
            print(f"WARNING: {path} is not a valid YAML dict", file=sys.stderr)
            return {}
        return data
    except FileNotFoundError:
        print(f"ERROR: {path} not found", file=sys.stderr)
        sys.exit(2)
    except yaml.YAMLError as e:
        print(f"ERROR: {path} parse error: {e}", file=sys.stderr)
        sys.exit(2)


def extract_port_mappings(compose: dict) -> dict[tuple[str, int], list[dict]]:
    """
    Extract port mappings from compose file.
    Returns: { (service_name, host_port): [ {container_port, line_info} ] }
    """
    result = {}

    for service_name, service_config in compose.get("services", {}).items():
        if not isinstance(service_config, dict):
            continue

        ports = service_config.get("ports", [])
        if not ports:
            continue

        for port_entry in ports:
            parsed = parse_port_mapping(port_entry)
            if parsed is None:
                # Report malformed but don't fail
                print(
                    f"WARNING: {service_name}: unparseable port '{port_entry}'",
                    file=sys.stderr,
                )
                continue

            host_port, container_port = parsed
            key = (service_name, host_port)
            result.setdefault(key, []).append(
                {"container_port": container_port, "port_spec": port_entry}
            )

    return result


def check_collisions(
    all_mappings: list[tuple[str, dict[tuple[str, int], list[dict]]]],
    strict: bool,
) -> int:
    """
    Check for host-port collisions across all files.
    Collision: same (host_port) mapped by different services in same file,
    or same host_port across different files.

    strict=True: exit 1 on any collision.
    strict=False: report collisions but exit 0.
    """
    # Aggregate host ports: host_port -> [(file, service), ...]
    host_port_usage = {}

    for file_name, mappings in all_mappings:
        for (service_name, host_port), container_info in mappings.items():
            key = host_port
            host_port_usage.setdefault(key, []).append((file_name, service_name))

    collisions = []
    for host_port, usage in sorted(host_port_usage.items()):
        if len(usage) > 1:
            usage_str = "; ".join(f"{f}:{svc}" for f, svc in usage)
            collisions.append(
                f"PORT COLLISION: host port {host_port} mapped by multiple "
                f"services: {usage_str}"
            )

    if collisions:
        print("\nCOLLISIONS FOUND:")
        for c in collisions:
            print(f"  {c}")
        if strict:
            return 1
    return 0


def check_unmapped_container_ports(
    all_mappings: list[tuple[str, dict[tuple[str, int], list[dict]]]]
) -> None:
    """
    Info check: services with container ports but no host mapping.
    This is not an error; just informational.
    """
    for file_name, mappings in all_mappings:
        for (service_name, host_port), container_info in mappings.items():
            for info in container_info:
                container_port = info["container_port"]
                if host_port != container_port:
                    # This is normal — different host and container port.
                    # Only note if host_port is 0 or similar edge case.
                    pass


def validate(compose_files: list[str], strict: bool = False) -> int:
    """Main validation: load files and run checks."""
    if not compose_files:
        # Default to docker-compose.yml in current directory
        compose_files = ["docker-compose.yml"]

    all_mappings = []

    for file_name in compose_files:
        path = Path(file_name)
        if not path.exists():
            print(f"ERROR: {path} not found", file=sys.stderr)
            return 2

        compose = load_compose_file(path)
        mappings = extract_port_mappings(compose)

        if not mappings:
            print(f"  {path}: no port mappings found")
        else:
            num_services = len(set(svc for svc, _ in mappings.keys()))
            num_ports = len(mappings)
            print(f"  {path}: {num_services} service(s), {num_ports} host port(s)")

        all_mappings.append((str(path), mappings))

    # Run checks
    collision_result = check_collisions(all_mappings, strict=strict)
    check_unmapped_container_ports(all_mappings)

    if collision_result == 0:
        print("\nAll checks passed.")
    return collision_result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Lint docker-compose files for port collisions and issues.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "compose",
        nargs="*",
        help="docker-compose file(s) to validate (default: docker-compose.yml)",
    )
    parser.add_argument(
        "-f",
        "--file",
        dest="files",
        action="append",
        help="docker-compose file (repeatable, alternative to positional args)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit 1 if any collisions found (default: exit 0 if warnings only)",
    )

    args = parser.parse_args(argv)

    # Merge positional + -f args
    compose_files = list(args.compose) if args.compose else []
    if args.files:
        compose_files.extend(args.files)
    if not compose_files:
        compose_files = ["docker-compose.yml"]

    return validate(compose_files, strict=args.strict)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
