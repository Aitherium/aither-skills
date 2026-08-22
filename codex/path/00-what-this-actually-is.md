# What this actually is — an agent is a loop with tools, not an oracle

*Chapter 0 of 4. About ten minutes. No setup yet — read this first, it changes
what you type later.*

---

## The one thing that reframes everything

A chatbot answers. A coding agent **runs a loop**:

```
  read your request
  ↓
  think
  ↓
  CALL A TOOL          <- read a file, run a command, search the web, edit code
  ↓
  read what came back  <- this is the part that makes it different
  ↓
  think again … repeat until done
```

That single difference — *it sees the result of its own action and reacts* — is
the whole thing. It means the agent can be **wrong and then find out**, which is
a capability, not a flaw. Your job is to make finding out cheap and automatic.

Everything in this codex follows from that. Eighteen laws about making it
possible for a machine to discover it was wrong.

## What it is genuinely good at

Not "writing code". More precisely:

- **Work that is tedious but mechanical.** Rename this across 200 files. Add this
  guard to every handler. Migrate this to the new API. These are the wins that
  compound.
- **Reading more than you can hold.** It will open forty files to answer a
  question you would have guessed at.
- **Doing the thing you already decided.** You know the fix. Describing it costs
  30 seconds; typing it costs 30 minutes.
- **Being an unlimited number of hands** when the work splits cleanly.

## What it is bad at, and will not tell you

- **Knowing whether it worked.** It will report success with total confidence
  because the code *looks* right. It has no independent way to check unless you
  give it one. This is the origin of every law in Part I.
- **Knowing what is true about *your* system today.** It knows a general truth
  from training. Your fleet, your ports, your conventions are not in there.
- **Noticing an absence.** If a tool it needed was never offered, it cannot
  observe that. It will just quietly do everything the long way.

## The single mistake everyone makes first

You ask for something. It produces something plausible. You skim it, it looks
fine, you merge it.

Two weeks later you find out it never worked — and the reason it never worked is
that **nothing in the loop could ever have discovered that.** No test, no probe,
no live check. The agent was not lying; it genuinely had no way to know.

The fix is not "trust it less". It is **give it a check that can fail** — a
command that goes red when the work is wrong. Then confidence is irrelevant,
because the loop can see.

> Most people try to solve this by writing more careful prompts. It does not
> work, because the thing missing is not in the prompt. It is in the environment.

## What "make it a fucking experience" actually means

Once the loop can verify itself, the way you work inverts:

- You stop typing careful instructions and start typing `fix it` and `keep going`.
- Your standards move out of your head and into files the agent reads every time.
- The system gets **harder to break over time** without anyone being careful —
  because every failure becomes a check, and checks accumulate.

Measured over 210 days on one real codebase: the median human prompt is **56
characters**. The precision did not disappear. It moved into the harness, which
now writes 2,986-character dispatches on your behalf at nearly two per prompt.

**You don't type your standards. You install them.**

---

**Next:** [01 · Your first hour](01-your-first-hour.md) — install one, point it
at real code, and get a change you can actually trust.
