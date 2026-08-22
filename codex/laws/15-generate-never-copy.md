# Generate, never copy — a comment asking people to keep two copies in step is not a gate
*Part IV · Deployment*

**Fires when:** you are about to duplicate a file, a rule set, or a helper
because the two places cannot import from each other.

## The law

Two copies of anything drift. Not *might* drift — do drift, on a schedule set by
how often either side changes. The only two acceptable states are:

1. **one copy**, imported by everyone; or
2. **one source and N generated mirrors**, with a checker that diffs them.

A comment saying "keep these in step" is not a third option. It has been tried.

## The evidence

**A shared browser worker.** One copy had been hardened over months with error
handlers, device-loss handling and a timeout breaker. The shared copy — used by
four other products — had **none of it**. The file carried a comment saying
exactly this: *"the fix never reached the shared copy. Keep them in step."* It
drifted anyway.

**Seventeen hand-copied modules.** A package was mirrored into a second tree by
hand, guarded by a check that compared **exactly three functions** and reported
OK. Measured: **14 of 17 modules had drifted.** Eleven differences were re-worded
prose — a human re-sanitising each docstring on every copy. Two were real
behaviour changes. And one was worse than drift: the copy had **lost a guard**,
so a commit touching a file with unresolved conflict markers recorded every
function in it as deleted — confidently wrong data in a log meant to be
authoritative. The test pinning that contract had been failing with an
`AttributeError`, which reads as a stale test rather than a missing guard.

**Forty private copies of one helper.** A shared module existed precisely so a
runtime ladder was written once. Its own docstring said *"import it; do not paste
a fourth copy."* Measured: **40 files carried their own copy and 0 imported the
shared one.** The module was a registry nothing rendered. Two corrections had
landed on the shared copy that month and **neither reached any of the 40** — so
each fix benefited exactly one file.

## Why you cannot always just import

Sometimes duplication is structural, and pretending otherwise ships a worse bug.
One package could not be re-exported through a shim because the build that
produces service images copies a different set of directories — the shim would
have worked perfectly on a developer machine and been a `ModuleNotFoundError` in
every container.

So when duplication is forced: **pick a source, generate the mirror, diff it in
CI.** Drift then stops being representable — you regenerate, or the gate is red.

## Diff the right thing

Two practical rules that decide whether the checker survives:

- **Compare only what must match.** One mirror check compares the shared rule
  vocabulary; the file paths, imports and error handling differ on purpose. A
  byte-diff there would be red forever and get deleted.
- **Normalise line endings.** One tree was CRLF and its source LF: a byte-exact
  comparison called 69 files stale where 10 were real. See
  [LAW 10](10-a-gate-that-floods-gets-switched-off.md).

## The check

```bash
python check_mirror.py            # exit 1 on drift
python check_mirror.py --write    # regenerate
python check_mirror.py --diff     # show what moved
```

And verify the checker by mutation ([LAW 4](04-mutate-the-test-not-just-the-code.md)):
delete one entry from the mirrored copy and confirm the tool names that entry.
