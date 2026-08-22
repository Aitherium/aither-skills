# A gate that floods gets switched off — being right too loudly is how a rule dies
*Part III · Adoption*

**Fires when:** a new rule's first run produces a lot of findings.

## The law

A rule's job is to be *acted on*. False positives do not merely waste time — they
teach people that this rule's output is noise, and that lesson generalises to
every rule you write afterwards. **A rule at 60% precision is worse than no rule**,
because the 40% trains everyone to skim.

Every per-file ignore list in every mature codebase is a fossil of this. Somebody
turned a rule on, it flooded, and instead of narrowing the rule they silenced it
per directory — permanently, invisibly, for every file added since.

## Five first runs, and what was wrong with them

| rule | first run | after narrowing | what was wrong |
|---|---:|---:|---|
| focus-stealing scheduled tasks | 7 false | 0 | classified by executable NAME; fixed by reading the PE subsystem header |
| manual-toil detection | 47 | 12 | inline heredocs collapsed every ad-hoc script into one meaningless row; shell keywords named findings after a *loop variable* |
| unshipped npm access flags | 5 (3 wrong) | 2 | it read the comment *explaining* the defect as the defect |
| dead tunnel origins | 23 (~22 wrong) | 17 | the container listing answered inconsistently under load — 40 on one read, 2 on the next |
| dropped environment keys | 939 | ~0 gated | keys arriving via an env-file were counted as dropped; **a number four times too large is worse than no number** |

Note the second column: every one of those rules survived. Narrowing is not
weakening.

## The recurring false-positive sources

1. **Comments and prose.** These files document their own past defects at length.
   Flagging the documentation of a defect as the defect is how a gate gets
   deleted rather than satisfied. **Strip comments before matching** — and anchor
   the stripper: a naive block-comment regex treats a host-permission string like
   `"http://*/*"` as opening a comment and eats the rest of the file.
2. **Ordinary English.** `lib` and `apps` are words. Anchor on *syntax* — an
   import statement, a module invocation — never on a bare noun.
3. **The rule matching itself.** A checker's own rule text contains the pattern
   it looks for. Exclude yourself explicitly; this happens on roughly every third
   new rule.
4. **A flaky source of truth.** If your inventory command disagrees with itself
   between two runs, you cannot build a rule on a diff of it. Retry, or pick a
   different question.

## The escape hatch, and its one condition

Where a violation is sometimes legitimate, allow an inline suppression — **with a
mandatory reason**:

```python
time.sleep(2)   # blocking-ok: boot path, before the loop starts
```

A bare `# blocking-ok` must NOT suppress. That single condition turns a silent
bypass into a visible decision, and it is the difference between an escape hatch
and a hole.

## The check

Your `--self-test` needs both halves ([LAW 3](03-watch-your-gate-fail.md)):
a fixture that must fail, **and a fixture that must pass**. The second is the
anti-flood assertion. Write a piece of prose containing your keywords and assert
the rule stays quiet on it.
