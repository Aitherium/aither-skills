#!/usr/bin/env bash
# install-aither-skills.sh — install the aither-skills pack into whatever agents you have.
#
# Two layouts exist in the wild and installing the wrong one is why an agent "can't see"
# skills that are sitting right there on disk:
#
#   folder : <root>/<name>/SKILL.md   — the agentskills.io standard (most agents)
#   flat   : <root>/<name>.md         — Claude Code slash commands
#
# This repo ships flat skills/*.md; we convert per target. Copies are byte-identical —
# only the path and filename change.
#
# Safe by default: never overwrites without --force, and --dry-run writes nothing.
#
# Usage:
#   bash scripts/install-aither-skills.sh [--dry-run] [--force] [--list]
#                                         [--target NAME[,NAME...]] [--only SKILL[,SKILL...]]
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills"
DRY_RUN=0; FORCE=0; LIST_ONLY=0; TARGETS=""; ONLY=""

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --list)    LIST_ONLY=1 ;;
    --target)  TARGETS="${2:-}"; shift ;;
    --only)    ONLY="${2:-}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ -d "$SRC_DIR" ] || die "skills/ not found next to this script — run it from a clone of the repo"

# name|layout|path  — path is expanded AFTER detection so $HOME/PWD resolve correctly.
# Agents relocate their config dirs between versions; if one is wrong for your version,
# check that agent's own docs. The LAYOUT is stable even when the PATH is not.
# `agents-shared` is the cross-agent `~/.agents/skills` convention (tau reads it, and it is
# designed for any agent to adopt) — installing there once can serve several agents.
TARGET_DEFS="
claude-code|flat|$HOME/.claude/commands
claude-code-skills|folder|$HOME/.claude/skills
openclaw|folder|$HOME/.openclaw/workspace/skills
hermes|folder|$HOME/.hermes/skills
tau|folder|$HOME/.tau/skills
agents-shared|folder|$HOME/.agents/skills
goose|folder|$HOME/.config/goose/skills
gemini|folder|$HOME/.gemini/skills
codex|folder|$HOME/.codex/skills
cursor|folder|$PWD/.cursor/skills
opencode|folder|$PWD/.opencode/skills
"

# An agent counts as present if its config ROOT exists — we do not create config dirs for
# agents that aren't installed, which would litter $HOME with empty trees.
detect_root() {
  case "$1" in
    claude-code|claude-code-skills) [ -d "$HOME/.claude" ] ;;
    openclaw)  [ -d "$HOME/.openclaw" ] ;;
    hermes)    [ -d "$HOME/.hermes" ] ;;
    tau)       [ -d "$HOME/.tau" ] ;;
    # No agent "owns" ~/.agents — treat the dir's existence as the opt-in signal.
    agents-shared) [ -d "$HOME/.agents" ] ;;
    goose)     [ -d "$HOME/.config/goose" ] ;;
    gemini)    [ -d "$HOME/.gemini" ] ;;
    codex)     [ -d "$HOME/.codex" ] ;;
    cursor)    [ -d "$PWD/.cursor" ] ;;
    opencode)  [ -d "$PWD/.opencode" ] ;;
    *) return 1 ;;
  esac
}

want_target() {
  [ -z "$TARGETS" ] && return 0
  case ",$TARGETS," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

want_skill() {
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

installed_total=0; skipped_total=0; targets_hit=0

printf '\n  aither-skills installer\n'
printf '  source: %s\n\n' "$SRC_DIR"

if [ "$LIST_ONLY" = 1 ]; then
  printf '  detected agents:\n'
  found=0
  while IFS='|' read -r name layout path; do
    [ -z "$name" ] && continue
    if detect_root "$name"; then printf '    %-20s %-7s %s\n' "$name" "$layout" "$path"; found=1; fi
  done <<< "$TARGET_DEFS"
  [ "$found" = 0 ] && printf '    (none — install an agent first, or pass --target explicitly)\n'
  printf '\n'
  exit 0
fi

while IFS='|' read -r name layout path; do
  [ -z "$name" ] && continue
  want_target "$name" || continue

  # --target is an explicit request: honour it even if auto-detection says the agent
  # isn't installed (the user may be provisioning a machine ahead of time).
  if [ -z "$TARGETS" ] && ! detect_root "$name"; then continue; fi

  targets_hit=$((targets_hit + 1))
  printf '  → %s (%s)\n    %s\n' "$name" "$layout" "$path"

  installed=0; skipped=0
  for src in "$SRC_DIR"/*.md; do
    [ -e "$src" ] || continue
    base="$(basename "$src" .md)"
    want_skill "$base" || continue

    if [ "$layout" = "folder" ]; then
      dest_dir="$path/$base"; dest="$dest_dir/SKILL.md"
    else
      dest_dir="$path";       dest="$path/$base.md"
    fi

    if [ -e "$dest" ] && [ "$FORCE" != 1 ]; then
      skipped=$((skipped + 1)); continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
      printf '      would write %s\n' "$dest"
    else
      mkdir -p "$dest_dir"
      cp "$src" "$dest"
    fi
    installed=$((installed + 1))
  done

  if [ "$DRY_RUN" = 1 ]; then
    printf '      %d would be installed, %d already present\n\n' "$installed" "$skipped"
  else
    printf '      %d installed, %d skipped (already present — use --force to overwrite)\n\n' \
      "$installed" "$skipped"
  fi
  installed_total=$((installed_total + installed))
  skipped_total=$((skipped_total + skipped))
done <<< "$TARGET_DEFS"

if [ "$targets_hit" = 0 ]; then
  printf '  No agents detected.\n\n'
  printf '  Install one first, or name it explicitly:\n'
  printf '    bash scripts/install-aither-skills.sh --target openclaw\n'
  printf '    bash scripts/install-aither-skills.sh --list\n\n'
  exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '  Dry run — nothing was written. Re-run without --dry-run to install.\n\n'
else
  printf '  Done: %d skill files installed across %d target(s).\n\n' "$installed_total" "$targets_hit"
  printf '  RESTART your agent — skills are read at startup.\n'
  printf '  Then ask it: "list the aither skills you can see"\n\n'
fi
