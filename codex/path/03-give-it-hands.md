# Give it hands — tools, skills and packs

*Chapter 3 of 4. The difference between an agent that answers and one that acts.*

---

## The three layers, and why they are different things

People collapse these into "plugins" and then cannot work out why their agent is
still useless. They are three separate mechanisms:

| layer | what it is | who executes it | when it loads |
|---|---|---|---|
| **a tool** | a function the model can call — read a file, query an API | your runtime | always visible |
| **a skill** | a *procedure* written in markdown — how to do a thing here | the model, by reading it | on demand |
| **a pack** | a bundle: identity + tools + skills, handed over wholesale | both | when installed |

**Tools are hands. Skills are knowledge. Packs are a job description.**

A common and expensive mistake: adding a tool when what was missing was a skill.
The agent could already do it — it just did not know that in *your* system the
thing is done a particular way.

## Tools: the part that is easy to get wrong

**A tool an agent holds by default is a decision, not a convenience.** Ship a
small default set and let everything else be granted on request. An agent with
thirty-five tools available and nine granted by default behaves noticeably better
than one holding all thirty-five — not for safety reasons, for attention reasons.

**A missing tool is a silence.** No error, no log line, no failed call. The agent
cannot notice a tool it was never offered; it will simply do everything the long
way, forever, and you will conclude it is not very good. Two consequences:

- **Enumerate your tool configs.** A project can hold more than one, and the one
  nearest the working directory wins. A correct config at the repo root proves
  nothing.
- Use `127.0.0.1`, not `localhost`. Measured on a Windows/WSL2 box: the IPv6
  loopback refused after **2120ms** where IPv4 connected in **3ms** — a two-second
  tax on every connection, and a hard failure for any client that does not walk to
  the next address.

## Skills: the highest-leverage thing you will write

A skill is a markdown file describing a procedure precisely enough that an agent
can execute it. No runtime, no framework, no build.

Write one the moment you notice yourself explaining the same thing twice. What
makes a good one:

```markdown
# deploy-the-api — ship an API change and prove it is live

## When to use
Any change under `api/`. Not for docs or frontend.

## Steps
1. `make test` - must be green before anything else
2. `make build && make push`
3. `kubectl rollout status deploy/api --timeout=120s`
4. **Verify:** `curl -fsS https://api.internal/version` returns the new SHA.
   If it returns the old one the rollout is not done - do NOT proceed.

## Traps
- The health endpoint answers during rollout. It is not proof. Use /version.
- Two replicas: check BOTH, they can disagree for minutes.
```

Note what earns its place: **the traps**. Anyone can write the happy path. The
value in a skill is the two lines that cost somebody a day.

Skills are also the natural home for the things this codex calls laws — a rule
that says *how* something is done here, loaded when it is relevant instead of
carried in every prompt.

## Packs: handing an agent a job

A pack bundles an identity, a tool set, a set of skills and a default posture.
That is what turns "a general assistant" into "the person who handles deploys".

The gate you need on day one: **a capability a pack declares must actually bind
to something.** A name in a pack's tool list is a promise — install this and
these tools are yours. One that binds to nothing is not a loud typo; it is a
capability the agent advertises, the catalogue prices, and the runtime silently
cannot provide. Measured on one pack: **five declared tools, all five phantom,
while the runtime served twelve the pack never named.**

## Escalation is a tool, and it is usually a lie

Every autonomous agent needs a way to reach a human. Check yours actually does
something. One `escalate_to_human` implementation wrote a log line and returned
`status: logged_locally` — **nothing was raised and the human was never told.**
The silent no-op living inside the one tool whose entire job is to get a person.

Two requirements:

1. It must **deliver** — asserted by round trip, not by return code
   ([LAW 9](../laws/09-detection-without-delivery-is-not-detection.md)).
2. It must **fail closed** — an unanswered escalation denies, never proceeds.

## Where to go next

- The whole [skills catalogue](../../skills/) — 70+ procedures, MIT licensed.
- [`awdk`](https://pypi.org/project/awdk/) — the agent runtime these
  packs are built for. `pip install awdk`.
- [`aither-adk`](https://pypi.org/project/aither-adk/) — the agent runtime these
  packs are built for. `pip install aither-adk`.
- The [eighteen laws](../README.md#the-eighteen-laws) — read Part I first.

---

*You now have the loop, the shape law, a local model, and hands. The rest of the
codex is about making the loop able to tell when it is wrong.*
