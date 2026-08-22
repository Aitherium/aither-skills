# A check that cannot run must not pass — silence is not a verdict
*Part II · Silence*

**Fires when:** writing any checker, probe, or health assertion.

## The law

Three outcomes, three exit codes. Never two.

```
exit 0  the invariant HOLDS — I looked and it is fine
exit 1  VIOLATION — I looked and it is broken
exit 2  DEAD — I could not look
```

"I could not look" is not "nothing is wrong". Collapsing exit 2 into exit 0 is
how *the checker is broken* gets filed as *the system is fine*, and it is the
single most common way a gate family rots while the dashboard stays green.

## The cases where this is the whole ballgame

**The gate whose subject is its own dependency.** A paging path posted alerts to
a monitoring service. On a calm day: `page -> HTTP 200`. During the outage it
existed for — a host reboot that took the resolver down — the monitoring service
was itself restarting, so the alert died in transit and **nobody was told for
nine hours.** The detection had worked perfectly: the probe ran, found 16
violations, and exited 1. The delivery is what failed. See
[LAW 9](09-detection-without-delivery-is-not-detection.md).

**The empty enumeration.** A checker that enumerates units, containers, workflows
or skills must exit 2 when it finds none. An empty list is the cleanest possible
pass, and on the one machine where a migration is actually happening it is also
the most likely result.

**The challenged probe.** A live checker fetched ~48 URLs and compared status
codes against 500. The CDN bot-challenged its default user agent and answered
**403 to everything** — and since 403 < 500, every single URL "passed". A total
blackout was indistinguishable from a perfectly clean run. Two fixes: send a real
user agent, **and treat a mostly-403 run as exit 2.**

**The pipe that eats the exit code.** `checker.py | tail; echo $?` reports
*tail's* status. That turned a red gate green in a transcript three times in one
session. Never pipe a gate. Capture the child's real return code.

## The reporting rule that goes with it

Anything you could not examine is **counted and printed**, never skipped in
silence. One tree walk skipped 26 unreadable files; if that number jumps, the
walk has lost coverage — which otherwise looks exactly like a clean scan.

The same applies to caps. If a run bounds its own coverage (top-N, sampling, no
retry), it must say what it dropped. Silent truncation reads as "covered
everything" when it did not.

## The check

```python
if not targets:
    print("NOT VERIFIED: enumerated 0 targets - refusing to report a pass")
    return 2
```

And in the runner that aggregates them, keep the two failures apart:

```
VIOLATION (1)  the invariant is broken
DEAD      (2)  a timeout, a missing tool, an unreadable host
```

Both must page. Conflating them is how a gate family quietly stops running.
