# Count the closure, not the edge — an import count is not a portability measurement
*Part V · Trust*

**Fires when:** you are deciding whether a file can be lifted out of a codebase
and shipped on its own — extracting a library, splitting a package, publishing
an internal tool, or estimating how much work a decoupling is.

## The law

The number of import lines in a file measures how many edges you can see from
where you are standing. It does not measure what the file needs in order to run
somewhere else, and it is wrong in **both** directions:

- **It under-counts reach.** One import of a local module can drag in that
  module's whole subtree. The count says one; the work is the transitive
  closure.
- **It over-counts cohesion.** Imports between files that travel *together*
  cost nothing on extraction — they become relative imports inside the package
  you are creating. The count says coupled; they are the thing itself.

So the useful question is never "how many imports does this file have". It is
**"what does this file need that a stranger's machine will not have?"** Count
that, and count it transitively, with internal edges excluded.

## The measurement that produced this

Five candidates were measured for extraction with a one-line command — imports
matching the monorepo's top-level packages, per file. The plan was built on the
result. Both of the two most confident readings were wrong, on the same run,
in opposite directions:

| candidate | lines | one-hop count | what was actually true |
|---|---|---|---|
| a client module | 1,020 | **3** | one of the three pulled a 653-line base class that itself pulled the HTTP client, the degradation registry, the port resolver, the TLS config and the request signer |
| a subpackage | 636 | **14** | **9 of the 14 were internal** — the subpackage importing itself. Real external coupling: 2 |
| a product engine | 3,867 | **1** | genuinely standalone, and the largest of the five was the easiest to ship |

The first row is the expensive one. "Three imports" was read as "an afternoon",
and the work it described was not decoupling at all: the correct move was to
**write a new thin client against the wire protocol** and treat the original as
a specification. Those are different tasks with different costs and different
outputs, and the metric chose the wrong one while looking precise.

The third row kills the intuition that size predicts portability. The biggest
candidate was the most portable. Lines and coupling are independent axes, and
only one of them decides whether the thing installs on someone else's laptop.

## The trap in the fix

The obvious repair is to compute the transitive closure and use that number
instead. Do that — but do not let it become the new oracle, because the closure
has the same shape of blind spot one level out:

**An import is not the only thing a file needs.** A module with zero internal
imports still fails on a stranger's machine if it reads a config file that is
not in the wheel, resolves a hostname only your network answers, expects an
environment variable your deploy sets, or imports a third-party package you
happen to have installed. None of those is an import edge, and none of them
appears in any count.

Which is why the number is a filter and never a verdict. The verdict comes from
**building the artifact and running it somewhere that has nothing** — a clean
container, a fresh virtualenv, a machine that has never seen your repository. A
package is not portable because you counted its imports. It is portable when it
imported successfully on a machine that could not possibly have helped it.

The counting is still worth doing. It is cheap, it ranks the work, and it tells
you which candidate to start with. It just never gets to be the last word,
because every failure mode it cannot see fails in the same place: on the
stranger's machine, days after you shipped, where you are not watching.
