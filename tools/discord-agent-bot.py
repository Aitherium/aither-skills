#!/usr/bin/env python3
"""Run any aither-adk agent as a self-service Discord bot.

> **Automated path:** `adk onboard --discord --identity <name>` does all of this
> in one command (validates the token live, prints the invite link, launches).
> This standalone launcher is the equivalent for older aither-adk, or for
> running the bot directly.

Loads an agent identity (and your installed agent packs), wires every DM and
@mention to the agent's own loop (tools + memory + inference), and replies in
Discord. Two client paths:

1. The built-in ``DiscordAdapter`` (``adk.channels``) when it is available and
   your account is entitled to the ``channels`` capability (a paid tier).
2. A hand-rolled ``discord.py`` client that calls ``agent.chat()`` directly —
   no entitlement required, so this works on **any** tier.

Run:

    pip install 'aither-adk[channels]'        # the agent toolkit + discord.py
    adk install pack:jgames-repair            # or any pack you've installed
    DISCORD_BOT_TOKEN=<token> python discord-agent-bot.py --identity jgames

Before connecting, prove the setup can fail honestly:

    python discord-agent-bot.py --check --identity jgames

Behavior lives in your pack: ``identity.yaml`` (persona/will/personality),
``skills/``, and your registered tools. Re-run the bot to apply changes.

The bot token is a secret — pass it via ``DISCORD_BOT_TOKEN`` (or ``--token``),
never commit it.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib
import os
import re
import sys

LIMIT = 2000  # Discord message length cap


def _chunk(text: str, limit: int = LIMIT) -> list[str]:
    """Split *text* on newlines up to ``limit`` (Discord's cap)."""
    if len(text) <= limit:
        return [text]
    out: list[str] = []
    while text:
        if len(text) <= limit:
            out.append(text)
            break
        cut = text.rfind("\n", 0, limit)
        if cut == -1:
            cut = limit
        out.append(text[:cut])
        text = text[cut:].lstrip("\n")
    return out


# ── Agent loading ───────────────────────────────────────────────────────────


def build_agent(identity: str, tools_module: str | None = None):
    """Construct an ``AitherAgent`` for *identity*, registering pack tools."""
    from adk import AitherAgent
    from adk.tools import get_global_registry

    if tools_module:
        # Import the module so its ``@tool``-decorated functions register into
        # aither-adk's global tool registry (same pattern as a pack's tools/).
        importlib.import_module(tools_module)
    tools = [get_global_registry()] if get_global_registry().list_tools() else None
    return AitherAgent(identity, tools=tools, load_packs=True)


async def agent_reply(agent, text: str) -> str:
    """Run one agent turn and return the reply text."""
    resp = await agent.chat(text)
    content = getattr(resp, "content", None)
    if isinstance(content, str) and content.strip():
        return content
    return str(resp)


# ── Discord client (works on any tier) ──────────────────────────────────────


def make_discord_client(agent):
    """Hand-rolled discord.py client: DMs + @mentions -> agent, chunked replies."""
    try:
        import discord
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("discord.py required: pip install 'aither-adk[channels]'") from exc

    class _Client(discord.Client):
        async def on_ready(self) -> None:
            print(f"  ✅ online as {self.user} — DM me or @mention me in a channel")

        async def on_message(self, message) -> None:  # noqa: N802 (discord.py hook)
            if message.author == self.user:
                return
            is_dm = message.guild is None
            is_mention = bool(self.user) and self.user in message.mentions
            if not (is_dm or is_mention):
                return
            text = message.content
            if is_mention and self.user:
                text = re.sub(rf"<@!?{self.user.id}>\s*", "", text).strip()
            reply = await agent_reply(agent, text)
            if reply:
                for chunk in _chunk(reply):
                    await message.channel.send(chunk)

    intents = discord.Intents.default()
    intents.message_content = True
    return _Client(intents=intents)


# ── Built-in adapter path (paid tier) ───────────────────────────────────────


async def try_builtin_adapter(token: str, agent) -> bool:
    """Start aither-adk's ``DiscordAdapter`` if available + entitled."""
    try:
        from adk.channels import DiscordAdapter

        async def handler(_platform, _channel_id, _user_id, text):
            return await agent_reply(agent, text)

        adapter = DiscordAdapter(token=token, on_message=handler)
    except Exception as exc:  # noqa: BLE001 — LicenseError/ImportError → fall back
        print(f"  (built-in DiscordAdapter unavailable: {exc})")
        return False

    await adapter.start()
    print("  running on aither-adk's DiscordAdapter (channels capability)")
    return True


# ── Check (a gate that can fail) ────────────────────────────────────────────


def run_check(identity: str, tools_module: str | None = None) -> int:
    """Validate identity + tool registration WITHOUT connecting to Discord."""
    try:
        from adk.identities import load_identity  # type: ignore[attr-defined]
    except ImportError:
        from adk.identity import load_identity

    ident = load_identity(identity)
    resolved = bool(ident.description or ident.system_prompt or ident.skills)
    print(f"  identity : {ident.name}")
    print(f"  role     : {ident.role}")
    desc = ident.description or ident.system_prompt or "(default — no identity file found)"
    print(f"  desc     : {desc}")
    if ident.skills:
        print(f"  skills   : {', '.join(ident.skills)}")
    if not resolved:
        print("  ⚠  identity did not resolve — run `adk install pack:<name>` and")
        print("     re-check, or pass `--identity` that exists (see `adk identities`).")

    tools = []
    if tools_module:
        importlib.import_module(tools_module)
    try:
        from adk.tools import get_global_registry
        tools = [t.name for t in get_global_registry().list_tools()]
    except Exception:  # noqa: BLE001
        pass
    print(f"  tools    : {', '.join(tools[:12]) if tools else '(none registered)'}")
    if tools:
        print(f"             ({len(tools)} total)")
    return 0 if resolved else 2


# ── Main ────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--identity", default=os.environ.get("ADK_AGENT", "aither"),
                    help="agent identity name (default: $ADK_AGENT or 'aither')")
    ap.add_argument("--token", default=os.environ.get("DISCORD_BOT_TOKEN", ""),
                    help="Discord bot token (or set DISCORD_BOT_TOKEN)")
    ap.add_argument("--tools-module", default=None,
                    help="optional python module path to import so its @tool tools register")
    ap.add_argument("--check", action="store_true",
                    help="dry-run: load identity + tools, print, exit — no Discord connection")
    args = ap.parse_args()

    if args.check:
        return run_check(args.identity, args.tools_module)

    if not args.token:
        print("✗ DISCORD_BOT_TOKEN is required (or pass --token).", file=sys.stderr)
        return 1

    print("Deploy your aither-adk agent as a Discord bot")
    print(f"  identity: {args.identity}")
    try:
        agent = build_agent(args.identity, args.tools_module)
    except Exception as exc:  # noqa: BLE001
        print(f"✗ could not build agent: {exc}", file=sys.stderr)
        return 1

    async def _run() -> int:
        if await try_builtin_adapter(args.token, agent):
            await asyncio.Event().wait()  # keep alive
            return 0
        client = make_discord_client(agent)
        try:
            await client.start(args.token)
        except KeyboardInterrupt:
            pass
        except Exception as exc:  # noqa: BLE001 — surface a clean, fail-closed message
            name = type(exc).__name__
            print(f"✗ could not connect to Discord ({name}): {exc}", file=sys.stderr)
            if "Improper token" in str(exc) or name == "LoginFailure":
                print("  → the bot token is invalid or revoked. Reset it in the "
                      "Discord Developer Portal and re-export DISCORD_BOT_TOKEN.",
                      file=sys.stderr)
            return 1
        finally:
            await client.close()
        return 0

    try:
        return asyncio.run(_run())
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
