#!/usr/bin/env python3
"""docker-net-doctor - find out WHY container networking/DNS is failing.

Written after a session that spent hours on a fleet-wide "intermittent DNS"
fault and reached the wrong conclusion three times. The order of checks below is
the order that would have found it in minutes.

THE HEADLINE FINDING IT ENCODES
-------------------------------
Docker's embedded resolver (127.0.0.11) is a userspace goroutine inside dockerd,
not a kernel service. On one fleet it was measured **failing 38-65% of queries
with clean 2000ms timeouts, sustained** - while the kernel reported zero loss:

    conntrack 11% used, 0 "table full"      <- NOT conntrack
    Udp InErrors=0 RcvbufErrors=0           <- NOT socket buffers
    load 22-32 on 24 cores, container CPU
      sum only 798% of 2400%                <- starved/blocked, not CPU-bound

Two things follow, and both are counter-intuitive:

  1. Nothing in the kernel will ever tell you about this. Every counter is clean.
  2. A *backup* resolver configured `--strict-order --server=127.0.0.11 ...`
     inherits the failure, because strict-order pays the bad upstream's full
     timeout on every cache miss. A backup that fails when the thing it backs up
     fails is not a backup.

You cannot make dockerd faster from inside a container. The durable fix is to
stop asking it: serve container names from a dnsmasq `hostsdir` map so a fleet
lookup never touches 127.0.0.11 at all.

USAGE
-----
    docker-net-doctor.py                 # everything
    docker-net-doctor.py pressure        # load vs cores, uncapped CPU hogs
    docker-net-doctor.py kernel          # conntrack + UDP error counters
    docker-net-doctor.py binds           # dnsmasq bind-race detector
    docker-net-doctor.py clients         # musl vs glibc resolver behaviour
    docker-net-doctor.py policy          # true resolv.conf per container

Exit 0 clean, 1 defect found, 2 could-not-determine (which is a FAILURE, not a
pass - a check that cannot run tells you nothing).
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys

RC_OK, RC_DEFECT, RC_UNKNOWN = 0, 1, 2
_findings: list[tuple[str, str]] = []


def _run(args: list[str], timeout: int = 60) -> tuple[int, str]:
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:  # noqa: BLE001 - a failed probe must not crash the doctor
        return 1, str(exc)


def _defect(name: str, detail: str) -> None:
    _findings.append((name, detail))
    print(f"  [DEFECT] {name}: {detail}")


def _ok(name: str, detail: str = "") -> None:
    print(f"  [ok    ] {name}" + (f" - {detail}" if detail else ""))


def _hostshell(script: str, timeout: int = 90) -> tuple[int, str]:
    """Run a shell snippet with the HOST network + privileges.

    A plain `docker exec` into a service container cannot see /proc/net or
    /proc/sys/net/netfilter for the VM. This can.
    """
    return _run(
        ["docker", "run", "--rm", "--net=host", "--privileged", "alpine", "sh", "-c", script],
        timeout=timeout,
    )


# -- 1. PRESSURE - check this FIRST -------------------------------------------

def check_pressure() -> None:
    """Load vs cores, and which containers are uncapped.

    First because it is the most common true cause and the cheapest to read. A
    DNS probe on a loaded box measures the load, not the resolver.
    """
    print("\n== PRESSURE (check this FIRST) ==")
    rc, out = _hostshell("nproc; cat /proc/loadavg")
    if rc != 0 or not out.strip():
        _defect("pressure", "could not read nproc//proc/loadavg - cannot judge scheduling")
        return
    lines = [ln for ln in out.splitlines() if ln.strip()]
    try:
        cores = int(lines[0].strip())
        load1, load5, load15 = (float(x) for x in lines[1].split()[:3])
    except (ValueError, IndexError):
        _defect("pressure", f"unparseable: {out[:120]!r}")
        return

    ratio = load15 / cores if cores else 0
    detail = f"load {load1:.1f}/{load5:.1f}/{load15:.1f} on {cores} cores (15m = {ratio:.0%} of capacity)"
    if ratio >= 0.9:
        _defect("pressure:saturated", detail + " - dockerd's resolver will miss client timeouts")
    elif ratio >= 0.6:
        _defect("pressure:elevated", detail + " - expect intermittent 2s DNS timeouts")
    else:
        _ok("pressure", detail)

    # Uncapped containers can starve system services during a burst.
    rc, out = _run(["docker", "ps", "--format", "{{.Names}}"])
    if rc != 0:
        return
    uncapped: list[str] = []
    for name in [n for n in out.split() if n][:400]:
        rc2, o2 = _run(
            ["docker", "inspect", name, "--format", "{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}"],
            timeout=20,
        )
        if rc2 == 0 and o2.strip().startswith("0|0"):
            uncapped.append(name)
    if uncapped:
        _defect(
            "pressure:uncapped",
            f"{len(uncapped)} container(s) have NO cpu limit - e.g. {', '.join(uncapped[:5])}",
        )
    else:
        _ok("pressure:uncapped", "every container has a cpu limit")


# -- 2. KERNEL - rule the popular theories OUT --------------------------------

def check_kernel() -> None:
    """conntrack + UDP counters.

    These are the two things everyone blames. Check them so you can RULE THEM
    OUT with numbers instead of arguing about them.
    """
    print("\n== KERNEL COUNTERS (rule out the popular theories) ==")
    rc, out = _hostshell(
        "echo C=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null);"
        "echo M=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null);"
        "echo FULL=$(dmesg 2>/dev/null | grep -ci 'table full');"
        "grep '^Udp:' /proc/net/snmp | tail -1"
    )
    if rc != 0:
        _defect("kernel", "could not read counters")
        return
    vals: dict[str, str] = {}
    udp_line = ""
    for ln in out.splitlines():
        if "=" in ln and not ln.startswith("Udp"):
            k, _, v = ln.partition("=")
            vals[k.strip()] = v.strip()
        elif ln.startswith("Udp:"):
            udp_line = ln

    try:
        cnt, mx = int(vals.get("C", "0")), int(vals.get("M", "1"))
        pct = cnt / mx if mx else 0
        if pct >= 0.8:
            _defect("kernel:conntrack", f"{cnt}/{mx} ({pct:.0%}) - table near full, packets WILL drop")
        else:
            _ok("kernel:conntrack", f"{cnt}/{mx} ({pct:.0%}) - not the cause")
    except ValueError:
        _defect("kernel:conntrack", "unparseable counters")

    if vals.get("FULL", "0") not in ("0", ""):
        _defect("kernel:conntrack-drops", f"dmesg reports {vals['FULL']} 'table full' events")

    if udp_line:
        parts = udp_line.split()[1:]
        # InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors ...
        try:
            in_err, rcvbuf = int(parts[2]), int(parts[4])
            if in_err or rcvbuf:
                _defect("kernel:udp", f"InErrors={in_err} RcvbufErrors={rcvbuf} - real packet loss")
            else:
                _ok("kernel:udp", "InErrors=0 RcvbufErrors=0 - kernel is NOT dropping DNS")
        except (ValueError, IndexError):
            _ok("kernel:udp", f"raw: {udp_line[:80]}")


# -- 3. BINDS - the silent dnsmasq startup race -------------------------------

def check_binds() -> None:
    """dnsmasq --bind-interfaces races Docker's IP assignment.

    It binds only the addresses that EXIST at exec time. If the container's IP
    is not attached yet it binds loopback only, then runs `Up (healthy)` forever
    serving NOTHING on the address every client is configured to use. Nothing
    logs an error, because a partial bind is not fatal to dnsmasq.
    """
    print("\n== dnsmasq BIND RACE (silent: Up + healthy + serving nothing) ==")
    rc, out = _run(["docker", "ps", "--format", "{{.Names}}"])
    if rc != 0:
        _defect("binds", "docker ps failed")
        return
    resolvers = [n for n in out.split() if "dns" in n.lower()]
    if not resolvers:
        _ok("binds", "no dns-named containers found")
        return

    for name in resolvers:
        rc2, cmd = _run(["docker", "inspect", name, "--format", "{{json .Config.Cmd}}"], timeout=20)
        if rc2 != 0 or "bind-interfaces" not in (cmd or ""):
            continue
        want = [tok.split("=", 1)[1] for tok in json.loads(cmd or "[]")
                if isinstance(tok, str) and tok.startswith("--listen-address=")]
        rc3, socks = _run(
            ["docker", "exec", name, "sh", "-c", "netstat -lnup 2>/dev/null | grep ':53 '"],
            timeout=25,
        )
        bound = [w for w in want if w in (socks or "")]
        missing = [w for w in want if w not in (socks or "")]
        if missing:
            _defect(
                f"binds:{name}",
                f"declared --listen-address {want} but only bound {bound}; MISSING {missing} "
                "- restart it once its IPs exist",
            )
        else:
            _ok(f"binds:{name}", f"all {len(want)} declared addresses bound")


# -- 4. CLIENTS - musl vs glibc behave DIFFERENTLY ----------------------------

def check_clients() -> None:
    """Why one container resolves and its neighbour does not.

    glibc walks the nameserver list and FAILS OVER, so a dead resolver costs
    latency but still resolves. musl (alpine) queries ALL nameservers in
    PARALLEL and uses the FIRST response - so one fast-failing resolver can beat
    a correct slower one, and `getaddrinfo` returns "bad address" while a
    sibling container is fine. nginx ignores both: it uses its own `resolver`
    directive and does not fail over inside a query.
    """
    print("\n== CLIENT RESOLVER SEMANTICS ==")
    print("  glibc : walks the list, FAILS OVER  -> slow but resolves")
    print("  musl  : queries ALL in PARALLEL, first response wins")
    print("          -> a fast FAILURE can beat a correct answer ('bad address')")
    print("  nginx : own `resolver` directive, no in-query failover")
    print("          -> one bad resolver = ~1/N of requests 502")
    print("  => 'wget fails but nginx works' in the SAME container is EXPECTED,")
    print("     not a contradiction. Never conclude from one client alone.")


# -- 5. POLICY - read the FILE, never HostConfig.Dns --------------------------

def check_policy(limit: int = 12) -> None:
    """`docker inspect .HostConfig.Dns` is empty for bind-mounted resolv.conf."""
    print("\n== RESOLVER POLICY (read the file, not HostConfig.Dns) ==")
    rc, out = _run(["docker", "ps", "--format", "{{.Names}}"])
    if rc != 0:
        _defect("policy", "docker ps failed")
        return
    seen: dict[str, list[str]] = {}
    for name in [n for n in out.split() if n][:limit]:
        rc2, conf = _run(
            ["docker", "exec", name, "sh", "-c", "grep '^nameserver' /etc/resolv.conf"], timeout=20
        )
        if rc2 != 0:
            continue
        key = " ".join(conf.split())
        seen.setdefault(key, []).append(name)
    if not seen:
        _defect("policy", "could not read resolv.conf from any container")
        return
    for key, names in sorted(seen.items(), key=lambda kv: -len(kv[1])):
        print(f"  [{len(names):>3}x] {key}")
        print(f"         e.g. {', '.join(names[:3])}")
    if len(seen) > 1:
        _defect("policy:divergent", f"{len(seen)} distinct resolver policies in use - expect uneven failures")


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if not shutil.which("docker"):
        print("docker not on PATH")
        return RC_UNKNOWN

    if mode in ("all", "pressure"):
        check_pressure()
    if mode in ("all", "kernel"):
        check_kernel()
    if mode in ("all", "binds"):
        check_binds()
    if mode in ("all", "clients"):
        check_clients()
    if mode in ("all", "policy"):
        check_policy()

    print("\n" + "=" * 62)
    if _findings:
        print(f"VERDICT: {len(_findings)} DEFECT(S) FOUND")
        for n, d in _findings:
            print(f"  - {n}: {d}")
        return RC_DEFECT
    print("VERDICT: no defects found by these checks")
    print("NOTE: a clean run on an IDLE box proves little - DNS faults here are")
    print("      load-shaped. Re-run under real load before calling it healthy.")
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
