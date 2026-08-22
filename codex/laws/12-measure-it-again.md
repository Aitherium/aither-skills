# Measure it again — every number in your docs is decaying right now
*Part III · Adoption*

**Fires when:** you write a count, a list, or a "which of these does X" into any
document an agent or a human will act on.

## The law

A measured number is true on the day it is measured and is drifting from that
moment. If a document states a fact about the running system, **something must
re-derive that fact and fail when the document is wrong.**

Do not hand-edit a measured list. Run the tool and paste what it measured.

## The list that was rewritten three times in one day, wrongly each time

A rules file carried the single most consequential operational fact in the
codebase: *which services pick up a code change on restart, and which need a
rebuild.* Get it wrong and you either waste 45 minutes rebuilding, or you claim a
fix is live when it is not.

It was corrected three times in one day and was wrong all three times, because
each pass measured a subset:

- the first checked one mount destination — missing six services that use another
- the second checked two — still missing the third
- the third used exact-destination matching, which is **blind to a parent mount**:
  one service mounts the whole parent directory, delivering the code without
  matching any of the three destinations. So the doc said "rebuild to deploy"
  while a plain restart shipped a fix to it — proven live that day, 52s to 22ms,
  by restart alone.

And the checker that was supposed to assert the whole thing shelled a container
engine the fleet no longer ran, so it printed `NOT VERIFIED` on every run instead
of catching any of it. See [LAW 8](08-a-checker-in-the-wrong-place-found-nothing.md).

## The three ways a number rots

**The world moved.** Services get added, renamed, retired. Any list of "the N
that do X" starts decaying the moment it is written.

**The counting rule changed.** The number can be wrong while the world is
unchanged, because your definition was incomplete — as above. When a count
changes, always ask which of the two moved.

**Nobody re-ran it.** A count published as a fact ("confirmed: production port
3100") was simply false when checked. The worst finding of one documentation
audit was a checklist item with a checkmark next to it.

## Make the document machine-readable on purpose

If a gate must assert a line in a document, that line's **spelling** becomes part
of the contract. One checker parsed a doc for `The \d+:` to find an enumerated
list; a later rewrite phrased it differently, and half the gate went silently
vacuous — passing, asserting nothing, for weeks.

So: pin the phrasing, and have the checker say which line it read.

## The check

Four questions a documentation gate should answer, all of them cheap:

```
1. broken links                      zero tolerance
2. paths that no longer resolve      baseline-gated
3. published figures                 RE-DERIVED from source, exact match
4. host-port ownership               read from the deployment config
```

Rules 3 and 4 exist because the audit that produced them found a confirmed,
checkmarked, published number that was false. **Never hand-edit a number to make
the check pass. Re-count.**
