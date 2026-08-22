# Run it on your own hardware — what a local model is actually good at

*Chapter 2 of 4. The honest version: what runs on your machine, what it is good
at, and how to find out without fooling yourself.*

---

## Why bother

Three reasons that survive scrutiny, and one that does not.

**It keeps working when nothing else does.** No account, no network, no vendor.
A model on your disk is an artifact you own.

**Latency you cannot buy.** A small model resident in memory answers in
milliseconds. For classification, routing, extraction and autocomplete, that beats
a smarter model behind a network hop — not on quality, on *being fast enough to
use in a loop*.

**Volume.** Anything you want to run over every file, every commit, every
request. The economics of a per-token bill and the economics of a machine you
already own are not comparable.

The reason that does *not* survive: "it's as good as the big one". It is not, and
believing that is how people conclude local models are useless — they measure the
wrong task and get the right answer to it.

## The size ladder, honestly

| roughly | runs on | genuinely good at | do not ask it to |
|---|---|---|---|
| **~0.5–2B** | a phone, a browser tab | classification, routing, extraction, tagging, autocomplete | reason across several steps |
| **~4–8B** | any laptop with 16GB | summarising, drafting, structured output, simple tool calls | multi-file refactors |
| **~12–30B** | one decent GPU | most day-to-day coding help, long-context reading | novel architecture |
| **~70B+ / MoE** | a workstation or a small cluster | genuinely competitive on hard work | fit in your laptop |

**A mixture-of-experts model has two budgets, not one, and they differ by an
order of magnitude.** Resident bytes — what you must hold — and bytes per token —
what you must move to generate. Size it by resident memory alone and you will
rank two models in exactly the wrong order.

## In-browser is real now

You can run a small model **inside a web page** with no install, over WebGPU.
Measured on ordinary hardware: **102ms to first token, ~50 tokens/sec.** On an
integrated laptop GPU the same runtime does ~1.9 tok/s — slow, and still a
working session.

Two traps that make it look broken when it is not:

- **A worker killed for memory posts no message and, on several engines, fires no
  error.** The UI sits at "generating" forever. Bind both the error handler *and*
  the message-error handler, and arm a deadline on first token — never on the
  whole generation, because slow is not dead.
- **Auto-starting on a phone.** Guard it, and handle the case where the browser
  reports no GPU information at all — one popular browser exposes none, so a
  guard spelled `info && !allowed(info)` silently permits everything on the single
  most affected device.

## The two rules for measuring, which matter more than any number

**Rule 1 · Score only the answers.** If your evaluation scores an exception, a
timeout or an empty response as a wrong answer, **a dead endpoint is
indistinguishable from a stupid model.** Every honest local-model comparison
starts by separating "did not answer" from "answered badly". Four separate
evaluation defects on one harness were all this one shape.

**Rule 2 · Verify the hardware was used.** Zero GPU utilisation is an *absence*,
not an error. A runtime that silently falls back to CPU produces correct output
at a fraction of the speed and reports nothing. Never publish a throughput number
without checking utilisation and that the runtime is actually linked against the
accelerator library.

A worked example of why this matters: a smaller specialised model was compared
against a large general one on 31 real tasks. The smaller one **won on matched
quality (0.831 vs 0.800) and used 19.4x fewer tokens** — and the large one failed
to answer 7 of the 31 at any budget. Score those 7 as wrong and you get the
opposite conclusion.

## Where local wins outright

**Route with the small one, escalate to the big one.** Classify the request
locally in milliseconds; only send the hard ones anywhere else. Most requests are
not hard.

**Anything privacy-shaped.** Documents, credentials, customer data, medical or
legal text. The question of whether a vendor retains it does not arise.

**Anything in a loop.** Per-keystroke, per-file, per-commit. This is where a
per-token bill stops being a rounding error.

---

**Next:** [03 · Give it hands](03-give-it-hands.md) — tools, skills and packs:
the difference between an agent that answers and one that acts.
