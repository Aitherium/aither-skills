# Design for the silence — the expensive failures do not raise
*Part II · Silence*

**Fires when:** always. This is the law that decides what you monitor.

## The law

The failures that cost days do not throw. They return 200. They render. They log
nothing, fail no test, and leave the container healthy. **A missing thing is
indistinguishable from a thing nobody wanted** — and no amount of care finds it,
because there is nothing to notice.

So: for every feature, ask what its *absence* would look like. If the answer is
"exactly like normal operation", you must write a check, because vigilance
cannot cover it.

## Eleven silences, all real, none of which raised

| what happened | what every signal said |
|---|---|
| A search API returned `count: 0` for an internal caller that named no tenant | **HTTP 200.** The collection held 5,462 documents. |
| An agent's escalate-to-human tool wrote a log line and returned `status: logged_locally` | success — nothing was raised and nobody was told |
| A worker was killed for memory mid-generation | no message, no error event; the UI said "generating" until the tab closed |
| A route was missing from an access manifest | **200 to bare `curl`, 403 to every authenticated user** — the gate runs only once a session exists |
| An extension's kill switch was written by a script as internal coordination | popup said "Connected — 5/5 services" for weeks |
| A capability was declared by a package and bound to nothing | the agent behaved as though the feature was configured off |
| A desktop app was listed in a registry and present in no renderer | a window opened saying "not installed here" |
| Login sessions were written to a node-local store instead of the shared one | 200, cookie set, works perfectly — until a second node serves that user |
| A public installer URL served a web page | `curl -fsSL` does not fail on a 200, so the one-liner piped HTML into `bash` |
| A blocking call landed on a shared event loop | `/health` answered in ~15ms *between* the stalls; the turn eventually succeeded with a checkmark |
| A publish pipeline's lint job went red | the push reported green; nothing shipped for ~28 hours and it was found by hand |

## The three shapes

Almost every silence is one of these:

1. **An empty collection.** Returned by success and by five kinds of failure.
   Fail-closed paths are especially good at this — see [LAW 17](17-fail-closed-then-prove-the-happy-path.md).
2. **An absent event.** Nothing arrives, so nothing handles it. The UI waits
   forever, which looks like slowness rather than death. Bind `onerror` *and*
   `onmessageerror`; arm a deadline when you enter a waiting state.
3. **A green signal from the wrong subject.** The healthcheck, the exit code, the
   container status and the dashboard are all reporting on something adjacent to
   the thing that broke — see [LAW 7](07-the-symptom-names-the-innocent.md).

## The check

Two habits close most of it:

**Assert the positive, live.** Every feature needs one check that the happy path
*produces data* — not that the unhappy path produces none. A suite that only
asserts denials is blind to a completely inert feature.

**Probe the surface, not the pipeline.** A red CI job proves a job failed, not
that users are affected; a green one proves neither. When a publish pipeline was
first diagnosed, the first diagnosis was also wrong — in the other direction —
because it was inferred from a workflow log without ever fetching the site. Fetch
the site.
