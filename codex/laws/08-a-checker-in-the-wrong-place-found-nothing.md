# A checker in the wrong place found nothing — and that is indistinguishable from a clean pass
*Part II · Silence*

**Fires when:** a checker resolves a root, enumerates a directory, or decides
what its own scope is.

## The law

Scope is an assertion, and it needs the same skepticism as the rule itself. A
checker pointed at the wrong tree returns exit 0 with a confident summary, and
there is no observable difference between *"I examined 102 files and they are
fine"* and *"I examined the wrong 8 files"*.

**Print what you scanned. Every run. As a count.**

## Four ways scope goes wrong

**A fixed number of parent directories.** `parents[2]` resolved one level too
shallow, into a subdirectory that happened to contain its own `.github/workflows`
with 8 files in it. Clean pass over 8; the 102 real workflows were never opened.
**Resolve a repository root by walking up to `.git`, never by counting.**

**Enumerating the wrong runtime.** A deploy checker shelled the `docker` binary
while the fleet ran a different container engine. It reported `NOT VERIFIED` on
every single run for weeks — which was the *correct* contract, and which read as
"the checker is broken" rather than "nobody is asserting this". A gate that
always says it could not look is not a gate.

**Looking only where declarations are supposed to live.** A parity checker read
every unit file in the declarative directory. A service deployed as a hand-typed
unit *outside* that directory was therefore **not judged clean — it was not
judged at all.** It carried 6 of 22 environment keys and 1 of 3 volumes relative
to its own source of truth, and the rule written for exactly that defect could
not fire, because there was nothing there for it to read.

**Probing only the root path.** A routing checker fetched `/` for every hostname.
One host answered **404 at the root** (a pass) while its most specific route — the
one carrying all the real traffic — was a hard 502 for every method. Path-scoped
rules are the ones that matter most and the ones a root probe cannot reach.

## The general form

> An absence and a clean result produce the same exit code unless you make them
> produce different output.

This is [LAW 5](05-design-for-the-silence.md) turned on the tooling itself, and
it is why [LAW 6](06-a-check-that-cannot-run-must-not-pass.md) insists on exit 2.

## The check

Three lines in every checker:

```python
targets = discover()
print(f"scanned {len(targets)} {noun} under {root}")
if not targets:
    return 2          # an empty scope is never a pass
```

Discover by **git**, not by a hardcoded path, wherever you can — `git ls-files`
knows about the tree you actually ship, and it will not silently miss a
directory somebody moved. And when a checker's own scope changes, re-run it
against the *pre-change* tree: if it does not reproduce the original defect, your
new scope is wrong.
