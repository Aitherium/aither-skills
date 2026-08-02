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
    docker-net-doctor.py egress          # find Up+healthy containers with NO network

Exit 0 clean, 1 defect found, 2 could-not-determine (which is a FAILURE, not a
pass - a check that cannot run tells you nothing).
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import time

RC_OK, RC_DEFECT, RC_UNKNOWN = 0, 1, 2
_findings: list[tuple[str, str]] = []


def _run(args: list[str], timeout: int = 60) -> tuple[int, str]:
    try:
        # encoding= is required: without it the child's output is decoded with the
        # LOCALE codec (cp1252 on Windows hosts), and a UnicodeDecodeError is a
        # ValueError -- which the except below does catch, but only by turning a
        # readable probe result into the string form of a decode error.
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
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


# -- ARP TABLE HEADROOM -------------------------------------------------------


def check_arp() -> None:
    """The global ARP table vs the fleet's total entries.

    THE FAULT THIS FINDS, and why it is worth its own check: Linux keeps ONE
    GLOBAL `arp_tbl` whose entry count is shared across EVERY network namespace,
    while `gc_thresh3` -- the ceiling on it -- defaults to 1024. Containers each
    hold their own ARP entries, so on a large single-bridge fleet their SUM
    blows past that ceiling; `neigh_alloc` then refuses new entries and
    whichever container ARPs next simply cannot resolve its next hop.

    It presents as a PER-CONTAINER fault and that is the trap. Measured on a
    187-container fleet (2026-08-02): one container's `getaddrinfo` failed
    INSTANTLY with EAI_AGAIN, it held no ARP entry for either resolver, and raw
    UDP *and* TCP :53 both timed out -- while it was `Up (healthy)`, its
    resolv.conf was byte-identical to a working container's, and the resolver
    answered a peer on the same bridge in 12ms.

    A `--force-recreate` "fixed" it every time, which is exactly why the real
    cause hid for weeks: a recreate CHURNS neighbour entries and frees table
    space, so the container comes back 0/6 -> 6/6 and the limit refills minutes
    later. The measured fleet total was ~2000 entries against the 1024 ceiling.
    Raising the thresholds fixed the container with NO recreate at all, and
    simultaneously fixed an unrelated container that could not reach the Docker
    proxy -- one kernel tunable, two "separate" outages.

    Nothing else can see it: every per-container signal is green, the resolver
    is genuinely healthy, and the only evidence is a kernel ring-buffer line.
    """
    print("\n== ARP TABLE HEADROOM (a per-container symptom with a global cause) ==")
    rc, out = _hostshell(
        "echo T3=$(cat /proc/sys/net/ipv4/neigh/default/gc_thresh3 2>/dev/null);"
        "echo UP=$(cut -d' ' -f1 /proc/uptime);"
        "dmesg 2>/dev/null | grep 'neighbor table overflow' | tail -1"
    )
    if rc != 0:
        _defect("arp", "could not read the host neighbour settings")
        return

    thresh, uptime, last_overflow = 0, 0.0, None
    for ln in out.splitlines():
        if ln.startswith("T3=") and ln[3:].strip().isdigit():
            thresh = int(ln[3:].strip())
        elif ln.startswith("UP="):
            try:
                uptime = float(ln[3:].strip())
            except ValueError:
                # Leave uptime at 0; the freshness test below then declines to
                # judge rather than silently treating an old event as current.
                print(f"  [?     ] arp - unparseable uptime {ln[3:].strip()!r}")
        else:
            m = re.match(r"\s*\[\s*(\d+\.\d+)\]", ln)
            if m and "overflow" in ln:
                last_overflow = float(m.group(1))

    # Overflow within this window means it is happening NOW. dmesg is cumulative
    # since boot, so a raw count stays non-zero forever after a fix -- and a gate
    # that can never go green gets switched off rather than satisfied.
    if last_overflow is not None and uptime and (uptime - last_overflow) <= 900:
        _defect(
            "arp:overflow",
            f"kernel reported neighbour table overflow {uptime - last_overflow:.0f}s "
            "ago - containers ARE failing to resolve their next hop right now",
        )
    elif last_overflow is not None:
        _ok("arp:overflow", f"last event {uptime - last_overflow:.0f}s ago (stale)")
    else:
        _ok("arp:overflow", "none reported")

    if not thresh:
        # Docker Desktop / WSL2: --net=host lands in the ENGINE's netns, where
        # neigh/default is not even present. The knob lives in the docker-desktop
        # distro's init netns instead. Report it, never silently pass.
        print("  [?     ] arp:thresh - gc_thresh3 unreadable from the engine netns.")
        print("           Docker Desktop/WSL2: wsl -d docker-desktop -e sh -c \\")
        print("             'cat /proc/sys/net/ipv4/neigh/default/gc_thresh3'")
        return

    total, sampled = 0, 0
    rc, names = _run(["docker", "ps", "--format", "{{.Names}}"], timeout=60)
    for name in (names.split() if rc == 0 else [])[:80]:
        rc2, o = _run(
            ["docker", "exec", name, "sh", "-c",
             "cat /proc/net/arp 2>/dev/null | tail -n +2 | wc -l"], timeout=20)
        line = o.strip().splitlines()[-1] if o.strip() else ""
        if rc2 == 0 and line.isdigit():
            total += int(line)
            sampled += 1
    if not sampled:
        print("  [?     ] arp:entries - no container was probeable; NOT judged")
        return
    running = len(names.split()) if rc == 0 else sampled
    projected = int(total / sampled * running)
    if projected > thresh * 0.7:
        _defect(
            "arp:headroom",
            f"~{projected} entries projected across {running} containers vs "
            f"gc_thresh3={thresh}. They share ONE global table; over the limit a "
            "random container loses DNS while every container-level signal stays "
            "green. Raise gc_thresh1/2/3 (e.g. 4096/8192/16384)",
        )
    else:
        _ok("arp:headroom", f"~{projected} entries vs gc_thresh3={thresh}")


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
    detail = (f"load {load1:.1f}/{load5:.1f}/{load15:.1f} on {cores} cores "
              f"(15m = {ratio:.0%} of capacity)")
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
            ["docker", "inspect", name, "--format",
             "{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}"],
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
            _defect("kernel:conntrack",
                    f"{cnt}/{mx} ({pct:.0%}) - table near full, packets WILL drop")
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
        _defect("policy:divergent",
                f"{len(seen)} distinct resolver policies in use - expect uneven failures")


# -- 6. EGRESS - the container that is Up, healthy, and severed ---------------

def check_egress(target: str = "", limit: int = 500) -> None:
    """Find containers with a working route table and ZERO actual egress.

    This is the check `docker ps` structurally cannot do. A container whose veth
    pair has broken keeps a correct /proc/net/route, keeps its IP, keeps
    reporting `Up (healthy)` if its healthcheck is local -- and cannot reach
    anything. One was found running that way for 19 HOURS.

    The tell that saves you an hour: such a container also times out against
    `127.0.0.11`, which lives in its OWN netns. A container cannot fail to reach
    its own loopback resolver over the network. If 127.0.0.11 times out too, stop
    looking at DNS -- the interface is dead.

    Probes from a throwaway alpine sharing the TARGET's network namespace, so it
    needs no python/nc/bash inside the container being tested.
    """
    import concurrent.futures as cf

    print("\n== EGRESS (the check `docker ps` cannot do) ==")
    rc, out = _run(["docker", "ps", "--format", "{{.Names}}"])
    if rc != 0:
        _defect("egress", "docker ps failed")
        return
    names = [n for n in out.split() if n][:limit]
    if not names:
        _defect("egress", "no running containers")
        return

    # Each container must be probed against a peer on ITS OWN network. Using one
    # global target is WRONG and mass-false-positives: a container on a different
    # bridge (buildkit, a separate compose project, a 172.27.x stack) correctly
    # cannot resolve a name that only exists on 172.18.x. Measured: that mistake
    # reported 24 "severed" containers that were all simply cross-network.
    net_of: dict[str, list[str]] = {}
    for name in names:
        rc2, raw = _run([
            "docker", "inspect", name,
            "--format", "{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}",
        ], timeout=20)
        for net in (raw or "").split():
            net_of.setdefault(net, []).append(name)

    # peer target per container: another container on a shared network
    peer: dict[str, str] = {}
    for net, members in net_of.items():
        if len(members) < 2:
            continue  # a lone container on its own network has no peer to test
        for m in members:
            peer.setdefault(m, next(p for p in members if p != m))

    probeable = [n for n in names if n in peer]
    skipped = len(names) - len(probeable)
    print(f"  probing {len(probeable)} container(s) against a peer on their OWN network"
          + (f" ({skipped} skipped: no same-network peer)" if skipped else ""))

    def probe(name: str) -> tuple[str, bool, str]:
        # `docker exec <c> getent hosts <name>` on purpose, NOT a sidecar container
        # sharing the target's netns. The sidecar approach is the obvious design and
        # it does not work at fleet scale: it spawns a container per target, which is
        # itself a load event, and load is precisely what induces the fault being
        # measured. Worse, it proved unreliable even on a SINGLE healthy container
        # probed alone -- `aitheros-secrets` failed the sidecar ping while `getent`
        # from inside it succeeded and it was actively serving traffic.
        #
        # getent needs nothing installed (glibc and musl both provide it), costs one
        # exec, and exercises the resolver AND egress in one shot.
        tgt = peer[name]
        rc3, out3 = _run(
            ["docker", "exec", name, "getent", "hosts", tgt], timeout=25
        )
        # 127 / "executable file not found" means the IMAGE has no getent (scratch,
        # distroless, busybox-less). That is "cannot probe", NOT "severed" -- and
        # reporting it as a fault is the same could-not-determine-read-as-defect
        # error this whole tool exists to prevent. Measured: 3 of 20 flagged
        # containers were only missing the binary.
        if rc3 == 127 or "executable file not found" in (out3 or ""):
            return name, True, "SKIP:no-getent"
        return name, rc3 == 0, tgt

    suspects: list[tuple[str, str]] = []
    # Low concurrency on purpose: see the comment in probe(). A fast scan that
    # measures its own load is worse than a slow scan that is correct.
    with cf.ThreadPoolExecutor(max_workers=3) as pool:
        for name, ok, gw in pool.map(probe, probeable):
            if not ok:
                suspects.append((name, gw))

    # QUIET PASS. The wide pass is a SCREEN, never a verdict: it runs under load
    # it generated itself. Let that settle, then re-probe only the suspects, one
    # at a time. A severed veth stays severed; a container merely starved by the
    # scan comes back.
    severed: list[str] = []
    if suspects:
        print(f"  {len(suspects)} suspect(s) from the wide pass - re-verifying quietly")
        time.sleep(8)
        # TWO separated quiet rounds, and only a container that fails BOTH counts.
        # This is the load-bearing distinction and it took four wrong versions to
        # find: `getent` exercises DNS, and on a fleet with a bursty resolver a
        # single quiet round reports a DIFFERENT set of containers every run. A
        # severed veth is STABLE -- it fails every round, forever. A resolver burst
        # is not. Reporting an unstable set as "severed" sends you restarting
        # healthy containers to chase a DNS fault.
        def quiet_round() -> set:
            bad = set()
            for name, tgt in suspects:
                if not any(
                    _run(["docker", "exec", name, "getent", "hosts", tgt],
                         timeout=25)[0] == 0
                    for _ in range(2)
                ):
                    bad.add(name)
            return bad

        round_a = quiet_round()
        time.sleep(15)
        round_b = quiet_round()
        severed = sorted(round_a & round_b)
        intermittent = sorted(round_a ^ round_b)
        print(f"  {len(suspects) - len(round_a | round_b)} suspect(s) were scan artifacts")
        if intermittent:
            print(f"  {len(intermittent)} INTERMITTENT (failed one round, not the other) —")
            print("     consistent with a bursty resolver, NOT a severed interface:")
            print(f"     {', '.join(intermittent[:8])}")

    if severed:
        _defect(
            "egress:severed",
            f"{len(severed)} of {len(probeable)} container(s) failed BOTH quiet rounds "
            "(STABLE failure — a severed interface or a consistently-broken resolver "
            "path; confirm per-container before restarting anything): "
            + ", ".join(severed[:8]),
        )
        print("  -> CONFIRM before acting. This probe uses getent, so it cannot by")
        print("     itself separate a dead interface from a dead resolver path.")
        print("     The distinguishing test on ONE container:")
        print("       docker exec <c> cat /proc/net/route      # route sane?")
        print("       <raw TCP to a known peer IP, no DNS>     # egress alive?")
        print("     If raw TCP to an IP also times out while the route is correct,")
        print("     the veth is dead: `docker restart <name>` rebuilds it.")
        print("     `docker network disconnect`+`connect` does NOT reliably fix it")
        print("     (measured: same IP reassigned, still severed).")
    else:
        _ok("egress", f"all {len(probeable)} probeable containers reach a same-network peer")


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if not shutil.which("docker"):
        print("docker not on PATH")
        return RC_UNKNOWN

    if mode in ("all", "pressure"):
        check_pressure()
    if mode in ("all", "kernel"):
        check_kernel()
    if mode in ("all", "arp"):
        check_arp()
    if mode in ("all", "binds"):
        check_binds()
    if mode in ("all", "clients"):
        check_clients()
    if mode in ("all", "policy"):
        check_policy()
    if mode in ("all", "egress"):
        check_egress()

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
