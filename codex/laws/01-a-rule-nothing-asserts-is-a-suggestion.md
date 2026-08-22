# A rule nothing asserts is a suggestion — the first law, and the one the other seventeen depend on
*Part I · Enforcement*

**Fires when:** you write a coding standard, a convention, a "we always…", or a
line in an agent rules file.

## The law

If no program can fail because of your rule, your rule is a preference that
happens to be written down. It will be cited as binding by people who have never
seen it enforced, and it will be quietly false long before anyone notices.

The test is one question: **what command exits non-zero when this is violated?**
If you cannot name it, you have not written a rule.

## The measurement that produced this

A quality-standards document listed seven Python rules. Every one of them was
cited in reviews as binding. Measured against what actually ran:

| rule | what was really happening |
|---|---|
| line length | in the linter's global ignore list — **29,902** over-length lines in the tree |
| import ordering | per-file-ignored in every directory that holds code |
| no swallowed exceptions | **2,746** handlers whose entire body was `pass` — no checker existed |
| no skip inside a test body | **150** files did it — no checker existed |
| three others | genuinely enforced |

**One of seven was real.** The document had been correct on the day it was
written and had rotted invisibly, because a document cannot rot loudly.

The same shape recurs everywhere once you look for it. A rules file said "use
`127.0.0.1`, never `localhost`" for weeks — while the procedure file telling
agents how to reconnect said `localhost`. An agent following the documented
procedure wrote the exact defect the rule existed to prevent.

## The trap in the fix

The obvious repair is to turn the ignores off. Do not do that first: the tree
opens at ~33,000 violations and the build is red forever, so the gate gets
bypassed rather than satisfied — which is precisely how the ignore lists came to
exist in the first place.

**Gate the changed lines, not the tree and not the file.** File-scoped, a
twenty-line edit to a legacy module has to fix thirteen unrelated long lines
first, and that gets bypassed too. The rule that survives contact with people is
*do not add a violation*. Report the backlog separately and never gate on it.

See [LAW 11 — Open green, ratchet down](11-open-green-ratchet-down.md) for the
general form.

## The check

Scope the rule to the diff:

```bash
# what CI runs on every pull request
python check_quality.py --changed origin/main

# the backlog - reporting only, never a gate
python check_quality.py --all
```

Run the linter **isolated from the project config**. The ambient config is what
disables these rules; reading it would reproduce exactly the hole the checker
exists to close.

And select rules by FAMILY, not one at a time. A checker originally scoped to two
specific rule codes let a third violation — written the same session, in the same
file — go straight through it.
