# Written is not deployed — ask the running thing, never the source
*Part IV · Deployment*

**Fires when:** you are about to say "that's fixed" or "that's live".

## The law

The code you wrote, the code in the image, and the code the process is executing
are three different things. Every cheap signal you have confirms the first one.

Before claiming a change is live, ask the **running process** — not the file, not
the commit, not the build log.

## The four gaps, each of which has independently cost a day

**1 · The build succeeded and shipped nothing.** A function was added, committed,
synced, and built with an exit-0 build. The image contained **zero occurrences of
it**, because the layer that copies source was cached. The endpoint 404'd while
every signal said deployed. Bust the cache with a varying build argument — and
note that declaring the argument without ever *varying* it pins it to a constant
forever, so the cache-bust is inert while looking present.

**2 · The build tagged something nothing runs.** A rebuild produced
`localhost/service:latest`. The deployment unit ran `registry.example/service:latest`.
Build reported success, restart reported success, **and the old image kept
serving.** Neither command was wrong; they were talking about different images.

**3 · A mount makes the FILE current, not the PROCESS.** This is the subtle one.
A live-mounted directory means your edit is visible inside the container
instantly — but a long-running process **never re-imports**. So:

- the file inside the container shows your fix
- the mount in the inspect output confirms it is live
- the healthcheck is green
- the process is still running the old code

Every cheap verification passes at once. One investigation burned five hypotheses
on an innocent service because the actual writer had imported the module **87
minutes before** the fix reached that file. The same class had been written down
in prose hours earlier, and prose did not stop the recurrence.

**4 · Two replicas on one mount disagree.** Restart one and not the other and
they run different code from the same files, indefinitely. **Restart both halves
of a pair.**

## The rule of thumb that replaces guessing

Do not memorise which services bake and which mount — that list decays
([LAW 12](12-measure-it-again.md)). Ask the container:

```bash
# does THIS container mount the tree I changed, or bake it?
<engine> inspect <container> \
  --format '{{range .Mounts}}{{.Destination}}={{.Source}} {{end}}'
```

Check **every** destination the tree could arrive at, and remember that a mount
of a *parent* directory delivers the child without matching any of them.

## The check

Two gates, and they are twins:

```
staleness   for MOUNTED code: is any file newer than the process start time?
            -> restart every container it names
hash-match  for BAKED code:   hash the file in the image against the source
            -> IDENTICAL is proof; anything else is UNKNOWN, never "not deployed"
```

That asymmetry is deliberate. A hash match is sound proof the file is live; a
mismatch has a dozen innocent explanations. Do not report a negative you cannot
support.

**Read a non-zero staleness result correctly:** this is a *pre-claim* gate, not a
fleet invariant to hold at zero. On a busy tree, other people's live edits will
stale containers constantly. Use it as *"I changed X — which running processes
still have the old X?"*, restart those, and require zero for **them**.
