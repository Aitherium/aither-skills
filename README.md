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

## More coming

Deploy helpers, secret-safety scanners, and other agent-ops glue are on the way. Star the repo to follow along — and PRs/issues welcome.

## License

[MIT](./LICENSE) © Aitherium. Use it, fork it, ship it.
