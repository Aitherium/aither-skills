# Mutate the test, not just the code — a fixture that cannot fail proves nothing
*Part I · Enforcement*

**Fires when:** a test passes and you are about to believe it.

## The law

Break the code on purpose and confirm the test goes red. If it stays green, the
test is not testing what its name says.

This is [LAW 3](03-watch-your-gate-fail.md) applied one level down, and it catches
a distinct failure: **a test that passes for the wrong reason.**

## The one that produced this law

A retry helper had to distinguish a transport-layer timeout (retry it) from a
genuine command failure (do not). One test asserted "a successful run is never
treated as a flap":

```python
# the fixture, first version
fine = CompletedProcess(args=["run"], returncode=0, stdout="rows\n", stderr="")
assert not is_transport_timeout(fine)
```

It passed. Then mutation testing deleted the `returncode == 0` guard from the
function under test — and the test **still passed**.

The reason is obvious afterwards and invisible while writing it: the fixture's
streams held no timeout marker, so with or without the guard there was nothing to
match either way. The test never exercised the branch it was named after. Fixed:

```python
# the fixture CARRIES the timeout marker on purpose, so ONLY the
# returncode == 0 guard can save it
fine = CompletedProcess(args=["run"], returncode=0, stdout="rows\n",
                        stderr="warning: transport timeout seen earlier, recovered\n")
```

Now deleting the guard fails the test. That is the difference between a test and
a decoration.

## Where this bites hardest

**Anything fail-closed.** A gate that denies everything passes every "does it
deny?" test perfectly while being completely inert. One licence gate answered
"not permitted" for **31 of 35** entries — because 31 had no record at all and
the resolver failed closed. Every denial test was green. The gate was doing
nothing. See [LAW 17](17-fail-closed-then-prove-the-happy-path.md).

**Anything that returns an empty collection.** Empty is the universal disguise.
An unauthorised call, a wrong key, a mismatched identifier, and "there genuinely
are none" all look identical downstream.

**Anything with a real-world encoding.** A matcher was written against a plain
ASCII fixture. The real stream was UTF-16LE, so decoded as UTF-8 the marker
arrived with a NUL between every character — and the ASCII fixture passed against
a matcher that could not read the real thing at all. **Build the fixture from a
captured real sample, not from what you assume the real sample looks like.**

## The practice

For each assertion you care about, ask: *what single line could I delete from the
implementation and still see this pass?* Delete it. Watch. Put it back.

Three mutations per critical assertion is a reasonable budget. Catching one is
worth more than a hundred new tests, because one of your existing tests was lying
and you now know which.
