#!/usr/bin/env bash
# agent-worktree-reaper.sh — find and safely reclaim git worktrees your AI agents
# created and never cleaned up.
#
# THE PROBLEM
# -----------
# Agent harnesses create a throwaway git worktree per isolated task (Claude Code's
# `isolation: "worktree"`, swarm/forge loops, parallel review fan-outs). The task
# ends, the worktree stays. Nothing reaps them.
#
# Measured on a real box (2026-07-26): `.claude/worktrees` held **295 GB across 32
# worktrees**, inside a checkout that had grown to **1.15 TB** — of which the actual
# `.git` was **4.7 GB**. The repo was 0.4% git and 99.6% agent debris and runtime data.
#
# Worse, worktrees are invisible to the usual instincts: `git status` in the main
# checkout is clean, `du` on `.git` looks normal, and the directory is dotfile-hidden.
#
# THE SAFETY GATE (get this wrong and you delete somebody's work)
# --------------------------------------------------------------
# A worktree is safe to delete only when it has:
#   1. no uncommitted TRACKED changes   -> git status --porcelain -uno
#   2. no commits missing from a remote -> git log HEAD --not --remotes
#
# 🪤 THE TRAP: `git log --branches --not --remotes` looks right and is WRONG.
# Worktrees share one object store, so `--branches` enumerates EVERY branch in the
# repo and returns the SAME number for every worktree — a repo-wide count that makes
# all of them look unsafe forever. You must anchor on `HEAD`. Verified live: the
# broken form reported "209 unpushed" for all 32 worktrees; the correct form
# reported 0 for 30 of them and 1 for two.
#
# Untracked files are deliberately NOT counted (`-uno`): build output and agent
# scratch is the bloat you are trying to remove, not work worth saving.
#
# Usage:
#   agent-worktree-reaper.sh                 # audit only (default, read-only)
#   agent-worktree-reaper.sh --archive DIR   # save diffs/patches of dirty trees
#   agent-worktree-reaper.sh --reap          # remove the SAFE ones
#   agent-worktree-reaper.sh --reap --all    # also remove dirty ones (archive first!)
#   AGENT_WT_KEEP="a b c" agent-worktree-reaper.sh --reap   # never touch these
#
# Env:
#   AGENT_WT_DIRS   space-separated worktree roots to scan
#                   (default: .claude/worktrees .worktrees .agent-worktrees)
#   AGENT_WT_KEEP   space-separated worktree names to always preserve

set -uo pipefail

MODE="audit"; ARCHIVE=""; ALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --reap)    MODE="reap" ;;
        --archive) ARCHIVE="${2:-}"; shift ;;
        --all)     ALL=1 ;;
        -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

ROOTS="${AGENT_WT_DIRS:-.claude/worktrees .worktrees .agent-worktrees}"
KEEP="${AGENT_WT_KEEP:-}"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 1; }

# --- discover -------------------------------------------------------------
FOUND=()
for r in $ROOTS; do
    [ -d "$r" ] || continue
    for d in "$r"/*/; do [ -d "$d" ] && FOUND+=("$d"); done
done

if [ "${#FOUND[@]}" -eq 0 ]; then
    echo "no agent worktrees found under: $ROOTS"
    echo "(registered worktrees: $(git worktree list 2>/dev/null | wc -l))"
    exit 0
fi

echo "found ${#FOUND[@]} worktree(s); git has $(git worktree list 2>/dev/null | wc -l) registered"
echo "  (a mismatch is normal drift — 'git worktree prune' reconciles it)"
echo

# --- audit ----------------------------------------------------------------
SAFE=(); DIRTY=()
printf "%-34s %-7s %-9s %-26s %s\n" NAME DIRTY UNPUSHED BRANCH VERDICT
for d in "${FOUND[@]}"; do
    n="$(basename "$d")"
    dirty="$(git -C "$d" status --porcelain -uno 2>/dev/null | wc -l)"
    # HEAD, not --branches. See THE TRAP above.
    unpushed="$(git -C "$d" log HEAD --not --remotes --oneline 2>/dev/null | wc -l)"
    br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"

    keep=0
    case " $KEEP " in *" $n "*) keep=1 ;; esac

    if [ "$keep" = 1 ]; then
        v="KEEP(pinned)"
    elif [ "${dirty:-0}" -eq 0 ] && [ "${unpushed:-0}" -eq 0 ]; then
        v="SAFE"; SAFE+=("$d")
    else
        v="DIRTY"; DIRTY+=("$d")
    fi
    printf "%-34s %-7s %-9s %-26s %s\n" "$n" "${dirty:-?}" "${unpushed:-?}" "${br:0:26}" "$v"
done
echo
echo "safe=${#SAFE[@]}  dirty=${#DIRTY[@]}"

# --- archive --------------------------------------------------------------
if [ -n "$ARCHIVE" ]; then
    mkdir -p "$ARCHIVE" || exit 1
    echo ">>> archiving dirty/unpushed worktrees to $ARCHIVE"
    for d in "${DIRTY[@]}"; do
        n="$(basename "$d")"
        git -C "$d" status --porcelain -uno   > "$ARCHIVE/$n.status.txt"   2>/dev/null
        git -C "$d" diff HEAD                 > "$ARCHIVE/$n.diff"        2>/dev/null
        git -C "$d" log HEAD --not --remotes --patch > "$ARCHIVE/$n.unpushed.patch" 2>/dev/null
    done
    echo ">>> archived ${#DIRTY[@]} worktree(s) — this is TEXT and tiny."
    echo "    (295 GB of worktrees produced 1.6 MB of diffs in the real case)"
fi

# --- reap -----------------------------------------------------------------
if [ "$MODE" = "reap" ]; then
    TARGETS=("${SAFE[@]}")
    if [ "$ALL" = 1 ]; then
        if [ -z "$ARCHIVE" ] && [ "${#DIRTY[@]}" -gt 0 ]; then
            echo >&2
            echo "REFUSING --all without --archive: ${#DIRTY[@]} worktree(s) have uncommitted" >&2
            echo "work. Re-run with --archive DIR so the deletion is reversible." >&2
            exit 1
        fi
        TARGETS+=("${DIRTY[@]}")
    fi

    [ "${#TARGETS[@]}" -eq 0 ] && { echo "nothing to reap"; exit 0; }

    echo ">>> reaping ${#TARGETS[@]} worktree(s) — this is I/O heavy and SLOW on"
    echo "    spinning/degraded disks. Hundreds of GB can take many minutes."
    ok=0
    for d in "${TARGETS[@]}"; do
        # `git worktree remove` also drops the registration; rm -rf alone leaves a
        # stale entry that later confuses `git worktree list`.
        if git worktree remove --force "$d" 2>/dev/null || rm -rf "$d" 2>/dev/null; then
            ok=$((ok+1)); echo "  reaped ($ok/${#TARGETS[@]}): $(basename "$d")"
        else
            echo "  FAILED: $(basename "$d")" >&2
        fi
    done
    git worktree prune 2>/dev/null
    echo ">>> reaped $ok; registrations pruned."
fi
