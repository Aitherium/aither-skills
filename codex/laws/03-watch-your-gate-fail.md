# Watch your gate fail — a checker nobody has seen fail is not a gate
*Part I · Enforcement*

**Fires when:** you finish writing any checker, test, or automated assertion.

## The law

Every checker ships with a `--self-test` that **deliberately breaks the thing it
asserts and proves the checker goes red.** Not a unit test of its helpers — a
demonstration that the alarm makes noise.

Without it you have a program that exits 0, and you are inferring that it exits 0
*because the invariant holds*. That inference has been wrong every time anyone
has bothered to check.

## Why this is not paranoia

Three real ways a checker returns a clean pass while asserting nothing:

**It scanned nothing.** A publish gate printed `0 files scanned … OK` and exited
0 on a public repository. Reading the exit code, it passed. Reading the count, it
had never examined a file. An empty tree is the cleanest possible pass.

**It looked in the wrong place.** A workflow checker resolved its repository root
by walking up a fixed number of directories. That landed one level too shallow,
in a subdirectory that happened to hold 8 workflow files. It reported a clean
pass over 8 while the 102 real ones went unexamined. See
[LAW 8](08-a-checker-in-the-wrong-place-found-nothing.md).

**Its rule was vacuous.** One rule read an optional list that, on the real tree,
was always empty — so it could never fire. That is a hole dressed up as coverage,
and it is worse than no rule, because now the dashboard is green for a reason.

**The number:** when a hygiene checker was first pointed at its own family, four
documented-and-wired gates had no self-test at all, and the family's headline
count in the docs was short by roughly 6x.

## What a self-test must actually do

```
--self-test must:
  1. construct a fixture that VIOLATES the invariant
  2. run the real rule against it
  3. exit non-zero if the rule did NOT fire      <- the assertion
  4. construct a fixture that SATISFIES it
  5. exit non-zero if the rule DID fire          <- the anti-flood assertion
```

Step 5 is not optional. A rule that fires on everything passes step 3 perfectly
and is useless — see [LAW 10](10-a-gate-that-floods-gets-switched-off.md).

## The corollaries

- **Exit non-zero when you cannot run.** A probe that could not judge is dead,
  not passing — [LAW 6](06-a-check-that-cannot-run-must-not-pass.md).
- **Wire it somewhere unattended.** A checker that runs only when someone
  remembers to read a rules file is documentation, not enforcement. In one audit,
  exactly **1 of 22** checkers ran anywhere unattended.
- **Print the allowlist on every run.** Any exception list must be visible each
  time and every entry must name a reason, or it quietly grows into the hole the
  gate was built to close.
