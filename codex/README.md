# The Developer Codex — how to run a coding agent so the result survives

This is the operating manual for a codebase where agents do most of the typing.

It is not advice. Every law below was a real failure first — something shipped
broken, cost a day, and got written down so it could not happen silently again.
The evidence is measured, and where a number appears it was counted rather than
estimated.

Read it in order the first time. After that it is a lookup table.

---

## Who this is for

**You have never used a coding agent.** Start at
[the path](path/00-what-this-actually-is.md). Four short chapters, about an hour,
and you will have an agent doing real work on your machine with a gate that can
tell you when it is wrong.

**You already use one and it keeps producing confident garbage.** Skip to
[LAW 1](laws/01-a-rule-nothing-asserts-is-a-suggestion.md). The problem is almost
never the model.

**You are building the harness itself.** The nineteen laws are the whole point.
Read [Silence](#ii--silence) first — those five are the ones that cost the most
per incident, because nothing tells you they happened.

---

## The path — from nothing to a working setup

| | |
|---|---|
| [00 · What this actually is](path/00-what-this-actually-is.md) | An agent is a loop with tools, not an oracle. What that changes about how you ask. |
| [01 · Your first hour](path/01-your-first-hour.md) | Install, point it at a real repo, and get one verified change. No toy examples. |
| [02 · Run it on your own hardware](path/02-your-own-hardware.md) | Local models: what a small model is genuinely good at, what it is not, and how to tell the difference by measuring rather than vibes. |
| [03 · Give it hands](path/03-give-it-hands.md) | Tools, skills and agent packs — the difference between an agent that answers and one that acts. |

## The doctrine — how to prompt and steer

Two skills in this pack carry the operating doctrine. They are mined from
27,939 prompts across 3,183 sessions over 210 days, re-measured on a disjoint
34-day window.

- [`code-like-david`](../skills/code-like-david.md) — the thirteen rules: prompt
  shape, live-proof gates, plan documents as files, persistent memory, when to
  orchestrate, when to compact, how to route models.
- [`ramble-driven-development`](../skills/ramble-driven-development.md) — the
  shape law. Median human prompt: 56 characters. The 5.9% over 1,000 chars carry
  78% of everything typed. There is nothing useful in between.

**The one sentence:** the fully-specified prompt still has to exist — you just
should not be the one typing it. You do not type your standards. You install them.

---

## The nineteen laws

### I · Enforcement
*A standard that nothing checks is a preference. These four are how a preference
becomes a property of the codebase.*

1. [A rule nothing asserts is a suggestion](laws/01-a-rule-nothing-asserts-is-a-suggestion.md)
2. [Make it a check, not a ticket](laws/02-make-it-a-check-not-a-ticket.md)
3. [Watch your gate fail](laws/03-watch-your-gate-fail.md)
4. [Mutate the test, not just the code](laws/04-mutate-the-test-not-just-the-code.md)

### II · Silence
*The expensive failures do not raise. They return 200, render correctly, log
nothing, and are indistinguishable from the feature never having been wanted.*

5. [Design for the silence](laws/05-design-for-the-silence.md)
6. [A check that cannot run must not pass](laws/06-a-check-that-cannot-run-must-not-pass.md)
7. [The symptom names the innocent](laws/07-the-symptom-names-the-innocent.md)
8. [A checker in the wrong place found nothing](laws/08-a-checker-in-the-wrong-place-found-nothing.md)
9. [Detection without delivery is not detection](laws/09-detection-without-delivery-is-not-detection.md)

### III · Adoption
*A gate only works while people keep it switched on. Most gates die of being
right too loudly.*

10. [A gate that floods gets switched off](laws/10-a-gate-that-floods-gets-switched-off.md)
11. [Open green, ratchet down](laws/11-open-green-ratchet-down.md)
12. [Measure it again](laws/12-measure-it-again.md)

### IV · Deployment
*The gap between the code you wrote and the code that is running is where the
day goes.*

13. [Written is not deployed](laws/13-written-is-not-deployed.md)
14. [You wrote it; that does not mean it ships](laws/14-you-wrote-it-that-does-not-mean-it-ships.md)
15. [Generate, never copy](laws/15-generate-never-copy.md)
16. [The defect lives in the union](laws/16-the-defect-lives-in-the-union.md)

### V · Trust
*Three patterns no linter will ever catch for you, because all three are semantic.*

17. [Fail closed, then prove the happy path](laws/17-fail-closed-then-prove-the-happy-path.md)
18. [Never trust the caller for an authorization decision](laws/18-never-trust-the-caller.md)
19. [Count the closure, not the edge](laws/19-count-the-closure-not-the-edge.md)

---

## How the laws are meant to be used

Not as a reading list. Each law names **the check that enforces it**, because a
law you have to remember is a law you will forget at 2am with a red build.

The working loop is four steps and it is the whole method:

```
something breaks
  → you fix it
  → you ask: could a check have caught this?
  → if yes, THE CHECK IS THE WORK. Write it, watch it fail, wire it somewhere
    unattended. Do not write a ticket.
```

A codebase run this way gets harder to break over time without anyone having to
be careful. That is the entire claim, and it is the only one worth making.

---

*Part of [awskills](../README.md) — MIT licensed, free to fork and adapt.*
*Part of [aither-skills](../README.md) — MIT licensed, free to fork and adapt.*
