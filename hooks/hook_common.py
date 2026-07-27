#!/usr/bin/env python3
"""Shared plumbing for the Stop hooks in this directory.

A Stop hook is handed one JSON object on stdin and must answer with one JSON
object on stdout:

    {}                                     -> let the turn end
    {"decision": "block", "reason": "..."}  -> make the agent keep working,
                                               showing it `reason`

Everything here is deliberately dependency-free (standard library only) and
never raises out of a hook: a broken gate that kills sessions gets deleted
within a day, so every failure path here degrades to "let the turn end".

TRANSCRIPT SHAPE
    `transcript_path` points at a JSONL file, one entry per line. The entries
    this code cares about look like:

        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "..."},
            {"type": "tool_use", "name": "Edit", "input": {"file_path": "..."}}]}}
        {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "..."}]}}
        {"type": "user", "message": {"role": "user", "content": "do the thing"}}

    Tool results come back as *user* entries, which is why "did the human say
    something" is `is_user_prompt()` below and not `role == "user"`.
"""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Any, Iterator

# Tools that write to the filesystem. Names are matched case-insensitively so
# this survives an agent that spells them differently.
WRITE_TOOLS = {
    "edit",
    "multiedit",
    "write",
    "notebookedit",
    "applypatch",
    "apply_patch",
    "str_replace_editor",
    "create_file",
    "fs_write_file",
}

# Tools that run a command. Their input carries the command line under one of
# COMMAND_KEYS.
SHELL_TOOLS = {"bash", "powershell", "shell", "run_command", "execute", "terminal"}

PATH_KEYS = ("file_path", "filePath", "path", "notebook_path", "notebookPath")
COMMAND_KEYS = ("command", "cmd", "script")


# --------------------------------------------------------------------------- io


def read_payload() -> dict[str, Any]:
    """The hook's stdin JSON, or {} if it is missing/unparseable."""
    try:
        raw = sys.stdin.read()
    except Exception:
        return {}
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def allow() -> None:
    """Let the turn end."""
    sys.stdout.write("{}")
    sys.exit(0)


def block(reason: str) -> None:
    """Refuse the turn end and show `reason` to the agent."""
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


def run_hook(decide) -> None:
    """Call `decide(payload, turn)`; allow on any error, and on the loop guard.

    `decide` calls block() or returns; returning means allow.
    """
    try:
        payload = read_payload()
        # Already continuing because a Stop hook blocked -> never block twice.
        if payload.get("stop_hook_active"):
            allow()
        entries = load_transcript(payload.get("transcript_path"))
        decide(payload, current_turn(entries))
    except SystemExit:
        raise
    except Exception as exc:  # never break a session over a gate
        sys.stderr.write(f"[warn] {os.path.basename(sys.argv[0])}: {exc}\n")
    allow()


# ------------------------------------------------------------------- transcript


def load_transcript(path: str | None) -> list[dict[str, Any]]:
    if not path or not os.path.isfile(path):
        return []
    entries: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue  # a partially-flushed last line is normal
            if isinstance(obj, dict):
                entries.append(obj)
    return entries


def _content_blocks(entry: dict[str, Any]) -> list[Any]:
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else entry.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return content if isinstance(content, list) else []


def _role(entry: dict[str, Any]) -> str:
    message = entry.get("message")
    if isinstance(message, dict) and message.get("role"):
        return str(message["role"])
    return str(entry.get("type") or "")


def is_user_prompt(entry: dict[str, Any]) -> bool:
    """A real human turn — not a tool result, not an injected reminder."""
    if _role(entry) != "user":
        return False
    if entry.get("isMeta") or entry.get("isVisibleInTranscriptOnly"):
        return False
    blocks = _content_blocks(entry)
    if not blocks:
        return False
    has_text = False
    for b in blocks:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_result":
            return False
        if b.get("type") == "text" and str(b.get("text", "")).strip():
            has_text = True
    return has_text


def current_turn(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Everything since the last human prompt — the work this Stop is ending."""
    for i in range(len(entries) - 1, -1, -1):
        if is_user_prompt(entries[i]):
            return entries[i:]
    return entries


def iter_tool_uses(turn: list[dict[str, Any]]) -> Iterator[tuple[str, dict[str, Any]]]:
    for entry in turn:
        if _role(entry) != "assistant":
            continue
        for b in _content_blocks(entry):
            if isinstance(b, dict) and b.get("type") == "tool_use":
                name = str(b.get("name") or "")
                tool_input = b.get("input")
                yield name, tool_input if isinstance(tool_input, dict) else {}


def written_paths(turn: list[dict[str, Any]]) -> list[str]:
    """Filesystem paths a write-tool targeted this turn, in order."""
    out: list[str] = []
    for name, tool_input in iter_tool_uses(turn):
        if name.lower() not in WRITE_TOOLS:
            continue
        for key in PATH_KEYS:
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                out.append(value.strip())
                break
    return out


def shell_commands(turn: list[dict[str, Any]]) -> list[str]:
    out: list[str] = []
    for name, tool_input in iter_tool_uses(turn):
        if name.lower() not in SHELL_TOOLS:
            continue
        for key in COMMAND_KEYS:
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                out.append(value)
                break
    return out


def assistant_text(turn: list[dict[str, Any]], last_message_only: bool = False) -> str:
    """Prose the agent wrote this turn (tool inputs excluded).

    `last_message_only` narrows it to the closing message — the summary a human
    actually reads, and the only place a completion claim really counts.
    """
    chunks: list[str] = []
    for entry in turn:
        if _role(entry) != "assistant":
            continue
        texts = [
            str(b.get("text", ""))
            for b in _content_blocks(entry)
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        if texts:
            chunks.append("\n".join(texts))
    if not chunks:
        return ""
    return chunks[-1] if last_message_only else "\n".join(chunks)


def matches(pattern: str, text: str) -> bool:
    return bool(re.search(pattern, text, re.IGNORECASE))
