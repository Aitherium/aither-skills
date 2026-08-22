# Make it a check, not a ticket — a mechanically-detectable defect must never be discharged by writing it down
*Part I · Enforcement*

**Fires when:** you find a defect and reach for the backlog.

## The law

Recording a defect is the cheapest possible response to finding one, and it feels
like work. It is not. If a program could detect the defect, then **writing the
detector is the discharge** — the ticket is not a smaller version of the fix, it
is a different activity that resembles one.

Sort every finding into exactly one of these:

| what you found | how you discharge it |
|---|---|
| a defect a static check could detect | **write or extend a checker + a self-test.** No ticket. |
| a defect only a live probe can see | **add it to something scheduled that pages.** No ticket. |
| genuinely one-off, not generalisable | a ticket — this is what a backlog is for |
| needs a human decision, or is legal/commercial | a ticket |
| you fixed it | a commit. Not a ticket. |

## The measurement

A debt ledger ran for nineteen days under a "record everything" rule. Result:
**~79 rows added per day against a paydown rate of ~4.2 per day** — a 19:1
deficit. The ledger stopped being a queue and became a write-only archive:

- 1,589 rows total
- **664 of them already declared themselves resolved** in an open table, because
  nobody had moved them
- the only automated consumer could see 154 of them
- **one defect class alone accounted for 123 rows** — the same mistake, made
  again, recorded again, for weeks

Those 123 rows are the whole argument. Every one was a human re-deriving a
procedure that had already been performed correctly at least once. A check would
have cost an afternoon and closed all of them.

## The status field is machine-read, or it is decoration

If you do keep a ledger, its state must be parseable. The archive above
accumulated **~1,200 distinct status strings** — "unverified", "mostly done",
"suspect", "may be fixed" — which is how the automated sweeper came to be blind
to 90% of its own queue.

Pick four words: `open` · `fixing` · `resolved` · `refuted`. First word on the
line; prose after it if you like.

## Prefer extending a checker to adding one

A checker family reaches the edge of what anyone will maintain at around twenty
tools. Design them multi-rule from the start — one tool asserting six invariants
over one subsystem beats six tools, and it is the only shape that stays
maintained.

## The check

Ask, before you open the backlog file:

> *Would a check have caught this?*

If yes, the check IS the work. And when there is genuinely nothing to record, say
so explicitly — "checked, no new debt: <one line why>". That is a valid answer.
Silence is not.
