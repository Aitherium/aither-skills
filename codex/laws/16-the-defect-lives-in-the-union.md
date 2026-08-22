# The defect lives in the union — every file is individually correct
*Part IV · Deployment*

**Fires when:** a property is defined jointly by two or more files, and no single
one of them is wrong.

## The law

Some invariants have no owner. Each file that participates is locally sane, every
test over each file passes, and the defect exists only in the *relationship*
between them — which nothing looks at, because looking at it is nobody's job.

**Name the invariant, put it in one checker, and make that checker the owner.**

## Five that were live, and what each cost

**Pricing.** A platform billed at nine price points and entitled at three. A
$249/month tier resolved to 39 tools while a $99 tier got 230. The plan table, the
tier map, the tool bands and the rank ladder lived in four different modules and
**each was individually sane.** Nothing could catch it, because a pricing defect
is a cross-file invariant by construction.

**Two container engines.** One service ran in both, and one host port was
published from both. Docker's healthcheck was green for its copy; the other
engine's unit was active for its copy; **every single-engine probe passed.** One
engine's tooling cannot see the other's containers. The defect existed only in the
union — and a reboot could have handed the platform's identity port to the copy
that could not answer.

**A protocol across two languages.** An enum in Python and a union type in
TypeScript naming the same set. Add a member to one and it renders in no lane —
no error, no failed test, just a thing that never appears.

**Two registries for one feature.** An app needs an entry in a manifest (which
*lists* it) and an entry in an import map (which *renders* it). Thirty-five apps
declared widgets nothing could render; two import entries were reachable only by
session restore; and one id was reserved for tenant isolation in a third file for
an app that **existed in neither of the other two** — a file describing the
isolation rules for something nobody had built.

**Config and its transcription.** A service was migrated to a new deployment
format by hand. Against its own source of truth, the new unit carried **6 of 22
environment keys and 1 of 3 volumes** — losing the internal CA mount, the
inference URL, and the admin allowlist containing the only person who needed
admin. The gate written for exactly that dropped-CA defect could not fire,
because it enumerated a directory the hand-written unit was not in
([LAW 8](08-a-checker-in-the-wrong-place-found-nothing.md)).

## The two sub-rules

**A migration is a transcription, and transcription loses things silently.** The
last case is not a *conflict* — it is an **omission**, and an omission is
invisible to every rule that compares two live things. Compare the copy to the
original, not the copy to itself.

**Generated mirrors beat detected drift.** Parity checkers detect drift *after*
someone writes it. Where you can generate one side from the other, do — then
drift is not representable at all. See [LAW 15](15-generate-never-copy.md).

## The check

Write one tool per *invariant*, not per file, and let it grow:

```
PL001  tool counts increase monotonically with price
PL002  throughput increases monotonically with price
PL003  no paid tier resolves below a free one
PL004  every plan is explicitly mapped to a tier
...
```

Known-open inversions go in an allowlist **inside the tool**, each naming a
ticket, printed on every run. And exit 2 — never 0 — if the tool could not import
one of the files it compares. A cross-file checker that can only read one side is
asserting nothing.
