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

### 🗜️ `model-quantization` — shrink an LLM to 4-bit, locally and free

Make a model fit where bf16 won't — on a smaller GPU, or beside another model on
the same card. [`tools/quantize_model.py`](tools/quantize_model.py) drives
[AutoRound](https://github.com/intel/auto-round) and bakes in the gotchas that
otherwise produce a broken or un-loadable artifact.

The default is **RTN** (round-to-nearest, `--iters 0`): weight-only, no
calibration data, no forward pass, ~<2 GB peak VRAM, ~1 minute. It runs on your
**CPU + GPU together** (host-RAM offload) — `$0`, fully local, and enough for
most models. Calibrated AWQ (`--iters > 0`) is higher quality but needs a real
GPU, and is **refused on architectures whose calibrated path crashes** (per-layer
head dims) with a clear steer back to RTN.

```bash
# Preview the plan — no weight load, no GPU, no write
python tools/quantize_model.py google/gemma-3-12b-it --dry-run

# RTN 4-bit, local + free (keeps lm_head + multimodal projectors in bf16)
python tools/quantize_model.py google/gemma-3-12b-it -o ./gemma-3-12b-it-awq

# Calibrated AWQ on a GPU (refused on het-head models — use RTN there)
python tools/quantize_model.py mistralai/Mistral-7B-Instruct-v0.3 \
  -o ./mistral-7b-awq --iters 200 --nsamples 128
```

What it gets right for you: uses **AutoRound, not llm-compressor** (which silently
downgrades `transformers`); keeps **`lm_head` + vision/audio projectors in bf16**
(vLLM loaders require it); exports **`compressed-tensors`** so un-quantized modules
stay plain; and **detects heterogeneous head dims** to avoid the calibrated-mode
crash. Serve the result with `vllm serve <outdir> --quantization awq_marlin`.

**As a Claude Code skill:** copy `skills/model-quantization.md` into
`.claude/commands/` and `tools/quantize_model.py` onto disk, then run
`/model-quantization <model-id> -o <outdir>`. The agent dry-runs first, runs RTN
by default, and reports the output path + serve command. Needs
`pip install auto-round torch transformers`.

### 🔄 `resume-all` — bring back every Claude Code session you lost

A reboot, a crash, or a closed terminal and your Claude Code conversations are gone — not
deleted, just *unfindable*. You reopen N terminals, `cd` into each project, run `claude`,
then `/resume` and squint at a list of UUIDs trying to remember which was which.

[`scripts/Resume-ClaudeSessions.ps1`](scripts/Resume-ClaudeSessions.ps1) reads Claude Code's
own session journals (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`), recovers each
session's **AI title, last prompt, working directory, git branch and last-active time**, lets
you pick, and reopens them — each in its own terminal tab or tmux window. Read-only against
your history; it never mutates the journals.

```bash
# interactive picker — choose which to bring back
pwsh -File scripts/Resume-ClaudeSessions.ps1

# reopen the most-recent session for every project directory, no prompt
pwsh -File scripts/Resume-ClaudeSessions.ps1 -PerDir -All

# only sessions matching some text, from the last day
pwsh -File scripts/Resume-ClaudeSessions.ps1 -Filter payments -LookbackHours 24

# over SSH? resume into tmux — the windows survive a disconnect
pwsh -File scripts/Resume-ClaudeSessions.ps1 -Tmux -Select 1,3
```

**Cross-platform** (PowerShell 7): Windows Terminal tabs on Windows, tmux windows anywhere,
Terminal.app on macOS — and if none of those exist it prints the commands rather than
pretending it launched something. `-DryRun` prints the resolved session ids to stdout.

> ⚠️ The gotcha this exists to solve: sub-agent sidechains (`agent-*.jsonl`) and workflow
> journals are rewritten constantly, so by write-time they **crowd out your real sessions**.
> A naive "most recently modified N journals" scan surfaces almost none of them. This filters
> to genuine top-level conversations *before* truncating the scan window.

**As a Claude Code skill:** copy `skills/resume-all.md` into `.claude/commands/` and the script
onto disk, then run `/resume-all` (or `/resume-all all`, or `/resume-all <filter text>`).

### 🕸️ `omninode-node` — join the OmniNode P2P inference mesh in one command

[OmniNode Protocol](https://github.com/SUM-INNOVATION/OmniNode-Protocol) (by **SUM-INNOVATION**) is a
trustless, peer-to-peer network that pools ordinary machines into a fabric big enough to run models no
single device could hold — *any device with a chip can become a node*. Standing one up shouldn't be a
ten-step wiki page.

[`scripts/omninode-node-up.sh`](scripts/omninode-node-up.sh) takes a fresh machine (Linux / macOS /
Windows-WSL2) from **nothing installed → a live, discoverable node**: detect hardware → install Rust if
missing → clone + build `omni-node` → verify two peers discover each other over libp2p/mDNS (or `--listen`
to run a persistent node). If [aither-adk](https://github.com/Aitherium/aither-adk) is present it can also
`adk mesh onboard` the node so your agents use it — one motion, not two projects.

```bash
./scripts/omninode-node-up.sh          # build + self-verify P2P discovery
./scripts/omninode-node-up.sh --listen # run a persistent mesh node
./scripts/omninode-node-up.sh --adk    # + enroll into AitherMesh for adk agents
```

Verified end-to-end on a 12-core Linux box: clone → build → `NODE OK`, P2P discovery live. See
[`skills/omninode-node.md`](skills/omninode-node.md). No credentials, no account, no central server.

### 🧩 The Aither substrate — set up and use aither-adk, AitherNode, AitherConnect, AitherZero & AitherMesh

Five skills for the coherent substrate the OmniNode node plugs into. Each is a "set it up, then use
it" guide grounded in real commands — standing up compute and having your agents use it is one
motion, not five projects.

| Skill | What it sets up |
|-------|-----------------|
| [`aither-adk`](skills/aither-adk.md) | The agent toolkit — `pip install aither-adk` → `adk onboard --quick` → `adk run`. Your model, your loop, your data on your box; manage from the portal. |
| [`aithernode`](skills/aithernode.md) | The *body* — a local MCP server (`adk mcp node`) exposing GPU, local inference, ComfyUI, and files to agents; or bootstrap the box as a full inference node. |
| [`aitherconnect`](skills/aitherconnect.md) | The seam — `adk connect` / `adk mesh onboard` (`--headscale` behind NAT) to wire a machine, agent, and browser into AitherOS and the mesh. |
| [`aitherzero`](skills/aitherzero.md) | The provisioner — one `config.psd1` + `bootstrap.ps1` to stand up bare-metal/on-prem/cloud/hybrid, with a generated-from-inventory config editor and `az_*` agent tools. |
| [`aithermesh`](skills/aithermesh.md) | The fabric — one playbook (`Invoke-AitherPlaybook deploy-mesh-agent`) to create a private WireGuard mesh, join nodes to the overlay, and deploy agents onto them; nodes defined in `config/nodes.yaml`. |
| [`bonsai-27b`](skills/bonsai-27b.md) | A model to run on a node — PrismML's 1-bit Bonsai-27B (`Q1_0`, 3.8 GB) served on a plain CPU box via the PrismML llama.cpp fork; a 27B model on a laptop. |

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
| [`tools/quantize_model.py`](tools/quantize_model.py) | Quantize an LLM to 4-bit with AutoRound. **RTN runs free on local CPU+GPU** (`--iters 0`, default); keeps `lm_head`/multimodal projectors in bf16, exports `compressed-tensors`, and refuses calibrated mode on het-head architectures that would crash. `--dry-run` to preview. |

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
