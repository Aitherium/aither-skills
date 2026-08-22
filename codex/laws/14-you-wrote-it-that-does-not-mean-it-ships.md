# You wrote it; that does not mean it ships — a file is tracked when the tooling says so
*Part IV · Deployment*

**Fires when:** you add a new file, a new package, or a new asset that something
reads at runtime.

## The law

Writing a file puts it on your disk. Nothing more. Whether it reaches a build, a
clone, an image or a published package is a separate question with a separate
answer, and every local signal — the tests, the type checker, the dev server —
answers the first question while you are asking the second.

**A file is not tracked because you wrote it. It is tracked when `git ls-files`
says so.**

## Four ways a file you wrote does not ship

**An unanchored ignore pattern.** A rule written for build artifacts — `logs/`,
`data/`, `build/`, `secrets/` — applies at **every depth**, so it also matches
identically-named *source* directories anywhere in the tree. Thirty-one source
files were found excluded from every clone this way. One of them was a data file
that shipped code read at runtime, so the published package raised
`FileNotFoundError` on first use. Nothing local can see it: the files are on
disk, so builds pass, tests pass, and `git status` is clean.

**A package whose manifest is untracked.** Source committed, `package.json` not.
It resolves locally through the workspace symlink, so tests and type-checking
pass — and then every image build dies with `Module not found`.

**An entry point that only exists at publish time.** Packages can declare one set
of entry points for local development and another that the registry swaps in on
publish. That means **the paths that actually ship are exactly the ones no local
build, no test and no type check ever exercises.** Neither publishing nor
installing resolves them, so the package publishes green, installs green, and
every import of it fails with an error naming the *consumer*. A published version
cannot be taken back.

**A dependency resolved by a build alias instead of declared.** A shared UI
package was pulled in by a bundler alias rather than a dependency entry — so
every "is this dependency vendored?" check looked straight past it. It shipped
absent (build failure, stale bundle served for two days), then shipped **stale**,
one commit behind. The stale half is invisible: the app passed a prop to a
component that no longer took that prop, and the framework **discards an unknown
prop without warning.** Build green, bundle valid, page renders, feature gone.

## The general shape

Every one of these is the same: **the artifact you tested is not the artifact you
shipped.** Local resolution is more forgiving than published resolution, in four
independent ways, and each forgiveness is a place a defect hides.

## The check

```bash
# the only authority on what ships
git ls-files <path> | head

# and for a package, resolve the PUBLISH entry points, not the local ones
python check_package_entrypoints.py --package <dir>
```

Run entry-point checks **after a build**, and have the checker say so when it
cannot judge — a package with a build script and no output directory has not been
verified, and reporting that as a pass is exactly the vacuous result
[LAW 6](06-a-check-that-cannot-run-must-not-pass.md) forbids.

One more, learned the hard way: **a green check proves the files are there, never
that the build put them there.** One package went green because somebody had
copied the missing assets in by hand. Delete the output directory, rebuild, and
check again before you believe it.
