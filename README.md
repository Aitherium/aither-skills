# aither-skills

**Free, MIT-licensed agent skills, scripts, and automations** — the unglamorous glue that makes agent-run infrastructure actually work.

Built and battle-tested inside [AitherOS](https://aitherium.com) (an AI-native operating system), pulled out here so anyone can use them. Recovery routines, deploy helpers, secret-safety scanners — small, sharp, reusable.

> Why this exists: agents operating real infrastructure need the infrastructure to be **self-healing and one-command operable**. If standing your environment back up is a 10-step wiki page, an autonomous agent can't recover from a bad state. These are the one-command versions.

## Layout

```
aither-skills/
├── skills/     # Claude Code slash commands (.md)
├── scripts/    # standalone scripts you can run directly
├── tools/      # MCP tools / CLI utilities
└── packs/      # themed bundles (docker, deploy, security)
```

## Skills

### 🐳 `recover-docker` — un-wedge Docker Desktop's WSL2 engine

Docker Desktop on Windows wedges its WSL2 Linux engine: the `docker` API returns **`500 Internal Server Error`**, or `docker stop`/recreate dies with **`tried to kill container, but did not receive an exit event`** (common on nvidia-runtime / GPU containers). The GUI looks healthy; the daemon is dead.

`scripts/Recover-Docker.ps1` does a complete teardown **in the right order** — kill the UI + backends → `wsl --shutdown` → reap `vmmem`/`wslservice` zombies → bounce the Windows services → cold-start Docker Desktop → wait for the engine → clean dead containers + restart exited ones. **No reboot, container volumes intact, healthy in ~30–60s.**

**Run it directly:**
```powershell
# one-shot recovery (run elevated for the service bounce)
pwsh -File scripts/Recover-Docker.ps1

# 30s watchdog — auto-recovers on failure
pwsh -File scripts/Recover-Docker.ps1 -Monitor
```

**As a Claude Code skill:** copy `skills/recover-docker.md` into your project's `.claude/commands/` and `scripts/Recover-Docker.ps1` somewhere on disk, then run `/recover-docker` (or `/recover-docker --monitor`). The agent detects the wedge, runs recovery, verifies with `docker version` / `docker ps`, and reports which containers came back.

📖 Background: [Self-Healing Docker: One Command to Un-Wedge the WSL2 Engine](https://aitherium.com/blog/recovering-docker-from-the-wsl2-wedge/)

### 🛡️ `moat-guard` — keep private code out of your public package

Open-core release hygiene. Three parameterized tools (nothing project-specific — every rule is a flag) plus a `/moat-guard` skill that drives them:

| Tool | Job |
|------|-----|
| [`tools/check_package_leaks.py`](tools/check_package_leaks.py) | **Pre-publish gate.** Inspect a built wheel/sdist; fail (non-zero exit) if it bundles forbidden files/imports or is missing a required keystone. Drop it in CI before `twine upload`. |
| [`tools/find_leaky_releases.py`](tools/find_leaky_releases.py) | **Audit what already shipped.** List index versions below a cutoff and, with `--verify`, download each wheel to *prove* the leak. Prints the exact yank checklist (indexes have no yank API). |
| [`tools/purge_public_leaks.sh`](tools/purge_public_leaks.sh) | **Scrub the public GitHub surface.** Delete pre-cutoff releases + tags and filter a leaked file out of the repo's entire history (mirror force-push). Dry-run by default. |

```bash
# CI gate: fail the build if it bundles secrets or imports an internal package
python tools/check_package_leaks.py dist/mypkg-2.0.0-py3-none-any.whl \
  --forbid-path '*/secrets*.py' --forbid-import mycorp_internal \
  --require-file '*/licensing.py'

# Audit a published project and prove which versions leak
python tools/find_leaky_releases.py mypkg --cutoff 2.0.0 --verify \
  --forbid-path '*/nanogpt.py'

# Plan a purge (dry-run), then execute once you've read it
bash tools/purge_public_leaks.sh --repo me/mypkg --keep-from 2.0.0 --leak-path src/secret.py
bash tools/purge_public_leaks.sh --repo me/mypkg --keep-from 2.0.0 --leak-path src/secret.py \
  --execute --rewrite-history          # irreversible — breaks pinned installs & forks
```

**As a Claude Code skill:** copy `skills/moat-guard.md` into `.claude/commands/` and run `/moat-guard check` (pre-publish), `/moat-guard find` (audit), or `/moat-guard purge` (destructive — always dry-runs first, confirms before force-pushing).

> ⚠️ Purging shrinks exposure but **cannot un-distribute** what already shipped. If a removed file carried a secret, rotate it.

### More skills (drop into `.claude/commands/`)

Generic, project-agnostic slash commands — pure prompt-skills, no code or dependencies:

| Skill | What it does |
|-------|--------------|
| [`secretguard`](skills/secretguard.md) | Scan git history for leaked secrets with **gitleaks**; purge a file from history (filter-repo) or allowlist a false positive. Never echoes secret values. |
| [`security-audit`](skills/security-audit.md) | Code + dependency + config audit against the OWASP Top 10 — injection, crypto, access control, secret exposure — with severity-ranked findings. |
| [`dependencies`](skills/dependencies.md) | Audit / update / prune dependencies and check licenses across pip, npm/yarn, and Docker base images (`pip-audit`, `npm audit`, `safety`). |
| [`performance`](skills/performance.md) | Profile and optimize: `cProfile`/`memory_profiler`, hotspot hunting, caching, N+1 queries, algorithmic complexity. Measure first. |
| [`refactor`](skills/refactor.md) | Apply clean-code refactors — extract method, replace conditionals with polymorphism, simplify nested logic — without changing behavior. |
| [`compare-versions`](skills/compare-versions.md) | Diff two versions of a file/commit/release: structural + behavioral changes, breaking-change risk, and a migration checklist. |

## Standalone tools

CLI utilities you can run directly — all parameterized, no AitherOS dependency:

| Tool | What it does |
|------|--------------|
| [`tools/check_exports.py`](tools/check_exports.py) | Validate a Python package: `__all__` entries that don't resolve (ghost exports), `__version__` vs `pyproject.toml` drift, and orphan modules nothing imports. Stdlib-only. |
| [`tools/validate_compose_ports.py`](tools/validate_compose_ports.py) | Lint docker-compose for **host-port collisions** (across one or many `-f` files), malformed mappings, and unpublished container ports. `--strict` to fail CI. |
| [`tools/Backup-DockerVolumes.ps1`](tools/Backup-DockerVolumes.ps1) | Snapshot Docker named volumes → timestamped `.tgz` + `manifest.json`, via a throwaway Alpine container. `-Pattern`/`-SkipPattern`/`-DryRun`, auto-prunes old snapshots. |

### PowerShell dev utilities ([`tools/powershell/`](tools/powershell/))

Standalone PS7 helpers — no module, no setup, just `pwsh -File`:

| Script | What it does |
|--------|--------------|
| `Invoke-FileGrep.ps1` | Recursive regex content search with context lines. |
| `Invoke-BulkReplace.ps1` | Regex find/replace across globs, with `-DryRun` and backreferences. |
| `Invoke-FileDiff.ps1` | Unified diff of two files (or inline strings). |
| `Invoke-FileSplice.ps1` | Surgically replace a line range in a text file. |
| `New-GitBranch.ps1` | Create a branch with a conventional prefix (configurable). |
| `New-GitCommit.ps1` | Stage + commit with Conventional Commits validation. |

## More coming

More agent-ops glue is on the way. Star the repo to follow along — and PRs/issues welcome.

## License

[MIT](./LICENSE) © Aitherium. Use it, fork it, ship it.
