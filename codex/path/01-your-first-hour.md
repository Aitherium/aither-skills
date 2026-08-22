# Your first hour — one real change, verified, on your own repo

*Chapter 1 of 4. About an hour. Use a real repository, not a toy one — the toy
never teaches you the thing that matters.*

---

## Step 1 · Install the doctrine before you install a habit

```bash
git clone https://github.com/Aitherium/awskills
cd awskills
bash scripts/install-awskills.sh      # Windows: pwsh -File scripts/Install-AitherSkills.ps1
git clone https://github.com/Aitherium/awskills
cd awskills
bash scripts/install-awskills.sh      # Windows: pwsh -File scripts/Install-AitherSkills.ps1
```

Then, in your agent: **"use the code-like-david skill"**.

It writes rules, plan templates and a memory scaffold into your config
directories without overwriting anything you already have. Do this *first* — the
habits you form in the first week are the ones you keep.

## Step 2 · Give it a map of your repo

Create a rules file at the root of your project. Most agents read one
automatically; check yours for the filename.

Keep it short and put **only the things that cost a session if you don't know
them**:

```markdown
# <project>

## Gotchas
- Tests: `make test` (NOT pytest directly - it needs the fixture server up)
- The `legacy/` tree is generated. Edit `schema/` and run `make gen`.
- Anything touching auth also needs `python check_authz.py <files>`.

## Done means
- `make test` green AND the change demonstrated against a running instance.
```

Do not put architecture diagrams in here. Put the traps.

## Step 3 · The prompt shape

Two modes, nothing in between.

**RAMBLE** when you are loading new intent. Unbounded, unedited, typos left in.
Say what you tried, what worries you, what "good" looks like, what you refuse to
do — and the tangent you are unsure about, which is usually the load-bearing
part. Then end with:

> *"Reflect that back as a clean brief, tell me what's missing and what you'd
> have gotten wrong, and ask clarifying questions before touching anything."*

**Never execute off a raw ramble.** The reflection step is the entire trick — it
is where you find out you were about to get the wrong thing built, for free.

**POKE** for everything else. Under sixty characters. The real measured
vocabulary: `continue` · `do it` · `status?` · `gap analysis` · `close the gaps` ·
`commit and push` · `run it` · `fix it`

**The anti-mode** is 200–800 characters of tidied-up professional-sounding
request. Too polished to carry your real intent, too short to be a spec. It is
what most people type all day and it is worse than either mode.

## Step 4 · The one habit that separates this from a toy

Every request carries its proof standard **in the same message**:

> build X — **done when** [something observable happens on a running system]

Not "and add tests after". In the same breath. Compare:

| what you type | what you get |
|---|---|
| "add caching to the user lookup" | plausible code, unknown behaviour |
| "add caching to the user lookup — done when a second identical request is served without a database query, shown in the query log" | a change and the evidence it works |

The second one is barely longer and it is a completely different transaction.

## Step 5 · Your first real change

Pick something genuinely annoying and mechanical. A rename across many files. A
guard that should be on every handler. A dependency bump that breaks 30 call
sites.

Then:

1. Ramble the intent. Read the reflection. Correct it *there*, before any code.
2. Let it work.
3. **Run the check yourself once.** Not to be suspicious — to find out whether
   your check can actually fail.

If you cannot make the check go red by breaking something on purpose, you do not
have a check. You have a habit that feels like one.
([LAW 3](../laws/03-watch-your-gate-fail.md))

## Step 6 · When it goes wrong — and it will

**It claims done and it isn't.** Your proof standard was not observable. Rewrite
it as something a command prints.

**It keeps making the same mistake.** Stop correcting it in chat. Put the
correction in the rules file. A correction typed twice is a rule you failed to
install. ([LAW 1](../laws/01-a-rule-nothing-asserts-is-a-suggestion.md))

**It went off and did something enormous.** Your ramble had no refusals in it.
Say what you will not accept — "don't touch the schema", "no new dependencies" —
in the ramble, not afterwards.

**It says a tool isn't available.** Check that your tool config is actually being
read, and check whether there is more than one config file — the one nearest your
working directory usually wins, and a correct one at the repo root proves nothing.

---

**Next:** [02 · Run it on your own hardware](02-your-own-hardware.md) — what a
model on your own machine is genuinely good at, and how to find out by measuring.
