# Open green, ratchet down — a gate that opens red gets bypassed, not satisfied
*Part III · Adoption*

**Fires when:** you want to enforce something on a tree that already violates it
hundreds of times.

## The law

You cannot go from 41 violations to zero in the commit that adds the rule. And a
gate that is red on day one is a gate someone disables on day two.

So **pin the current count and let it move in one direction only:**

```python
# Measured on the day this rule was written. Ratchets DOWN only:
#  - a higher count is new drift and fails immediately
#  - a lower count means remediation landed WITHOUT lowering the pin,
#    which also fails, so a win cannot be banked silently
PRIVATE_LADDER_PIN = 40
```

Both directions matter. The second is the one people forget, and it is what
separates a ratchet from a high-water mark: if fixing five violations does not
require you to edit the pin, the next five regressions are free.

## Why the equality, not an inequality

Pins in production use `count == PIN`, not `count <= PIN`:

- **higher** — new sprawl, fail now, name the new items
- **lower** — remediation landed; lower the pin *in the same commit*, or the
  ground you gained is given back the first time someone regresses

## What a pin looks like in practice

Real ones, all live:

| what is pinned | at | why it cannot be zero yet |
|---|---:|---|
| private copies of one shared helper | 40 | migrating 40 gates is its own project |
| jobs on a runner label that cannot run | 234 | most of a CI estate; the fix is per-workflow |
| catalogued models with no licence record | 31 | each entry needs a human to read a licence |
| skills waiting to be ported to the public pack | 21 | 14 of them import monorepo-only packages |
| declared capabilities that bind to nothing | 76 | shrinks with each pack fixed |

Note the last column. **A pin must name why it is not zero**, or it is
indistinguishable from an abandoned rule.

## The failure mode this replaces

Before pinning, the same information existed as a probe that printed
`LOCAL BUT UNDISTRIBUTABLE: <36 names>` and **always exited 0**. That is a
measurement, not a gate. Two things went wrong with it:

1. The number never moved — which is what a difference-without-a-decision always
   does.
2. It could not distinguish **"not done yet"** from **"must never be done"**.
   Fifteen internal runbooks sat in that list next to genuinely publishable
   skills, indistinguishable on every run. **The list read as a TODO, so the
   action it invited was publishing one of them** — a disclosure dressed as
   progress.

The fix was to record the decision per item, with a reason, and gate on the
decision rather than on the count alone. A reasonless exception exits non-zero:
a hole dressed up as a decision is still a hole.

## The check

```python
if actual > PIN:
    fail(f"{actual - PIN} new violations - the pin is {PIN}")
if actual < PIN:
    fail(f"remediation landed ({actual} < {PIN}) - lower the pin in this commit")
```

Print every pinned item on every run. A list nobody sees is a list that grows.
