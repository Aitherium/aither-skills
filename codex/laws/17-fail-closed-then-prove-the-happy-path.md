# Fail closed, then prove the happy path — a gate that denies everything passes every denial test
*Part V · Trust*

**Fires when:** writing or reviewing any function that decides whether something
is allowed.

## The law

Two halves, and almost everyone ships only the first.

**Half one — deny on every non-happy path.** Error, `None`, empty, timeout,
unparseable, unknown: all of them return the deny value. Any function named
`*gate*`, `*allow*`, `*owns*`, `check_*`, `verify_*`, `require_*`, `*_ok` must
have no path that reaches an allow by accident.

```python
except Exception:
    return True      # <- this is the bug. Every time.
```

**Half two — assert the happy path produces data, live.** This is the half that
gets skipped, and it hides a total outage.

## Why half one alone is a trap

A fail-closed path that **always** returns empty passes every "returns nothing"
assertion trivially. A test suite that only asserts denials is structurally blind
to a completely inert feature.

Measured: a licence gate decided whether a platform could commercially serve a
model, and answered `False` for any model with no record. **31 of 35 catalogued
models had no record**, so that fail-closed answer was returned for nearly
everything — permissive models included. Every "does it deny?" test was green.
The gate had never once said yes to anything.

> A gate that denies everything passes every denial test while being completely
> inert. That is the one failure mode a denial test cannot see.

## The silent no-op, in four disguises

Same shape, four surfaces, all live:

- **A missing credential.** An internal call with no auth header 401s, and the
  universal idiom `if response.status_code == 200:` with no `else` turns a
  permanently rejected call into "nothing matched".
- **A wrong body shape.** A framework drops an unknown key, then rejects the
  request for the missing required one — a 422 the caller never reads.
- **An unnamed scope.** A vector search with no tenant filter fails **closed to
  an empty list with HTTP 200**, no error and no log. Measured: a search returned
  `count: 0` while the collection reported its 5,462 documents.
- **An identity mismatch.** A value registered under one key and looked up under
  another. Zero matches, forever, silently.

Those four had **stacked**: one knowledge pipeline had never once succeeded, and
fixing any single break only revealed the next.

## The check

The static half is mechanical — find the allow-on-error:

```
SEC001  a security-named function returns the allow value from an except/None/default path
SEC002  an outbound call with certificate verification switched off
        (trust your own internal CA instead - never disable the check)
SEC003  an internal service call carrying no identity header
```

The semantic half is a review question you answer out loud against the diff:

> Which line proves the happy path returns real data, on a live system, not a
> mock?

If there isn't one, the feature is unverified regardless of how green the suite
is. Watch especially for cross-tenant reads: assert that the wrong tenant gets
nothing **and** that the right tenant gets something.

---

*Footnote, and it is the point of [LAW 10](10-a-gate-that-floods-gets-switched-off.md):
the first draft of this file was **blocked by a pre-commit hook** — which matched
the disable-verification flag inside the paragraph telling you never to use it.
Flagging the documentation of a defect as the defect is the most common way a
good rule earns its way to being switched off. Strip comments and prose before
matching, or accept that your rule will one day be deleted rather than fixed.*
