# Detection without delivery is not detection — the alert path is the one thing you cannot verify by using it
*Part II · Silence*

**Fires when:** you build anything that is supposed to tell a human something.

## The law

Every gate in this codex assumes an answer to one question nobody checks: **when
a gate fails, does anyone find out?**

An alert that reaches only a dashboard has paged nobody — the dashboard is on the
machine that is on fire.

## The nine-hour outage where detection worked perfectly

A host rebooted. A DNS service lost a race for its own static address, the tunnel
daemon could not resolve the edge, and every public hostname served 503 while 129
containers reported `Up` and healthy.

**Detection was flawless.** The scheduled probe ran at 05:06, found 16 violations
and 50 dead checks, and exited 1. Here is the whole story in two log lines:

```
[01:34] page -> monitoring HTTP 200 (host-direct)      <- paged fine on a calm day
[05:06] PAGE FAILED: ... NOT DELIVERED                 <- the outage, unreported
```

It failed exactly when it was needed, and that was **structural**:

- **The primary required the monitoring service to be up.** In a reboot-induced
  outage the monitor is itself restarting. The primary path shares a failure
  domain with its own subject, so it is *guaranteed* unavailable in the one
  scenario that matters.
- **The fallback was worse.** It shelled a container engine that had been
  replaced, named a container that had been renamed, used a network prefix that no
  longer existed, and **pulled a curl image from a registry — during a network
  outage.** A fallback whose dependencies are a strict superset of the primary's
  is not a fallback.
- **A fifth trap:** the monitor answered `https` on a calm day and `http` after
  the reboot. Pinning either spelling is a latent outage; try both.

Nine hours. The only signal was the owner opening a browser.

## The corollary about breakers

The same incident had a circuit breaker that never tripped. It banked a failure
only *after* a 150-second wait the process never survived — so its failure counter
sat at 0, last written 50 days earlier, while the attempt counter climbed to 43.

**A breaker that never trips is indistinguishable from one that never needed to.**
Assert the counter moves.

## The check

One rule, and it must post through **the real function**, not a hand-rolled
request. A probe posting its own request proves only that the sink accepts
requests, which was never in doubt.

```
PPD001  a page sent through the production page() function LANDS in the sink
        - asserted by ROUND TRIP, never by return code
        - page() returns True on any 2xx, and accepted is not recorded
PPD002  the alert can LEAVE THE BOX
        - an alert that reaches only the local dashboard has paged nobody
```

And the constraint that makes this a design decision rather than a config change:
**a total-outage page must egress independently of the fleet it reports on.** With
no working resolver, an email path could not have resolved its own relay either.

> Redundancy that is never exercised is not redundancy. It is two broken paths
> instead of one.
