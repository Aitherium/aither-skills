#!/usr/bin/env bash
# repo-hygiene-audit.sh — a GATE THAT CAN FAIL for the two architectural rules
# that keep agent-driven repos from silently eating a disk.
#
#   RULE 1  A repository is a SOURCE artifact, not a runtime.
#           Nothing a service or agent WRITES may live inside the checkout.
#   RULE 2  Every ephemeral resource an agent creates must have a REAPER.
#           Created-by + TTL + something that deletes it. Otherwise it is forever.
#
# WHY (measured, 2026-07-26): a checkout reached **1.15 TB** of which `.git` was
# **4.7 GB** — 0.4% repository, 99.6% runtime data and agent debris:
#     data/                490 GB   service runtime state written inside the repo
#     .claude/worktrees/   295 GB   32 abandoned agent worktrees, nothing reaped them
#     AitherOS/            237 GB   training data / models committed beside source
#     .iso-out/             40 GB   build artifacts
# Reaping the worktrees alone returned **299 GB**.
#
# Doctrine without a gate is a wish. This is the gate. Wire it into CI or a
# pre-push hook so the ratio cannot drift back.
#
# Usage:
#   repo-hygiene-audit.sh                # audit, exit 1 on violation
#   repo-hygiene-audit.sh --warn         # never fail the build, just report
#   REPO_MAX_NONGIT_RATIO=20 ...         # allowed non-.git multiple (default 10)
#   REPO_RUNTIME_DIRS="data logs out"    # extra dirs that must not be in-tree
#   REPO_WT_MAX_AGE_DAYS=3               # ephemeral worktree TTL (default 7)

set -uo pipefail
WARN_ONLY=0; DEEP=0
for a in "$@"; do
    case "$a" in
        --warn) WARN_ONLY=1 ;;
        --deep) DEEP=1 ;;
        -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    esac
done

MAX_RATIO="${REPO_MAX_NONGIT_RATIO:-10}"
WT_MAX_AGE="${REPO_WT_MAX_AGE_DAYS:-7}"
EXTRA_RUNTIME="${REPO_RUNTIME_DIRS:-}"

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

FAIL=0
_violation() { echo "  VIOLATION: $*"; FAIL=1; }

# Bounded measurement. `du` on a bloated tree is SLOW — the very repos this audit
# exists for are the ones where a full walk takes minutes (measured: `du -sm .` on
# a 1.15 TB checkout never finished inside a 9-minute budget). Every size probe is
# therefore time-boxed and degrades to "?" rather than hanging the gate.
_GB_TIMEOUT="${REPO_AUDIT_DU_TIMEOUT:-60}"
_gb() {
    local out
    out="$(timeout "$_GB_TIMEOUT" du -sm "$1" 2>/dev/null | awk '{printf "%.1f", $1/1024}')"
    [ -n "$out" ] && echo "$out" || echo "?"
}

echo "=== repo-hygiene-audit: $ROOT ==="
echo

# ── RULE 1a — the source:runtime ratio ────────────────────────────────────
# `.git` is the only thing that is unambiguously *the repository*. If the
# working tree dwarfs it by more than MAX_RATIO, the checkout is storing
# something that is not source.
# The whole-tree walk is the expensive one, so it is OPT-IN via --deep. The
# named-directory check below (1b) catches the same problem far more cheaply and
# names the actual offender, which is what you need to fix it anyway.
echo "RULE 1a — is this still a source repository?"
if [ "$DEEP" = 1 ]; then
    git_gb="$(_gb .git)"
    all_gb="$(_gb .)"
    if [ "$git_gb" != "?" ] && [ "$all_gb" != "?" ]; then
        ratio="$(awk -v a="$all_gb" -v g="$git_gb" 'BEGIN{ if(g>0) printf "%.0f", a/g; else print 999 }')"
        printf "  .git=%s GB   working tree=%s GB   ratio=%sx (limit %sx)\n" \
            "$git_gb" "$all_gb" "$ratio" "$MAX_RATIO"
        [ "${ratio:-0}" -gt "$MAX_RATIO" ] && \
            _violation "working tree is ${ratio}x .git — it is storing non-source data"
    else
        echo "  (measurement timed out — a tree too big to walk in ${_GB_TIMEOUT}s is"
        echo "   itself the finding; see RULE 1b for the offending directories)"
    fi
else
    echo "  skipped (whole-tree walk). Re-run with --deep for the .git:worktree ratio."
fi
echo

# ── RULE 1b — named runtime dirs must not be in-tree ──────────────────────
echo "RULE 1b — runtime/output directories inside the checkout"
for d in data logs out dist output artifacts .iso-out .build-tars \
         .hf-cache .cache kaggle-training-data $EXTRA_RUNTIME; do
    [ -d "$d" ] || continue
    sz="$(_gb "$d")"
    if [ "$sz" = "?" ]; then
        # Handle the unmeasurable case EXPLICITLY. Left to awk, "?" >= "1.0" is a
        # STRING comparison that happens to be true by ASCII ('?' > '1') — the right
        # verdict for the wrong reason, and it would silently invert if the sentinel
        # ever changed. A directory that cannot be walked in ${_GB_TIMEOUT}s is, by
        # itself, far too large to be sitting in a source tree.
        _violation "$d/ too large to measure in ${_GB_TIMEOUT}s — that alone disqualifies it from the checkout"
        continue
    fi
    # Under 1GB is noise; the failure mode is tens-to-hundreds of GB.
    big="$(awk -v s="$sz" 'BEGIN{print (s+0>=1.0)?1:0}')"
    if [ "$big" = "1" ]; then
        _violation "$d/ = ${sz} GB in-tree — every worktree and backup pays for this"
    else
        printf "  ok: %s/ = %s GB\n" "$d" "$sz"
    fi
done
echo

# ── RULE 2 — ephemeral resources need a reaper ────────────────────────────
echo "RULE 2 — unreaped agent worktrees"
wt_total="$(git worktree list 2>/dev/null | wc -l)"
stale=0
# Enumerate from git, NOT a directory glob: agent harnesses scatter worktrees
# outside any single parent dir, and a glob silently misses them.
while read -r w; do
    [ -d "$w" ] || continue
    [ "$w" = "$ROOT" ] && continue
    if [ -n "$(find "$w" -maxdepth 0 -mtime "+$WT_MAX_AGE" 2>/dev/null)" ]; then
        stale=$((stale+1))
    fi
done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')

printf "  registered worktrees=%s   older than %sd=%s\n" "$wt_total" "$WT_MAX_AGE" "$stale"
[ "$stale" -gt 0 ] && \
    _violation "$stale worktree(s) older than ${WT_MAX_AGE}d — run agent-worktree-reaper.sh"

# Registration drift: `rm -rf` on a worktree leaves the registration behind.
on_disk=0
while read -r w; do [ -d "$w" ] && on_disk=$((on_disk+1)); done \
    < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
if [ "$wt_total" -ne "$on_disk" ]; then
    _violation "worktree drift: $wt_total registered vs $on_disk on disk — run 'git worktree prune'"
fi
echo

# ── verdict ───────────────────────────────────────────────────────────────
if [ "$FAIL" = 0 ]; then
    echo "PASS — repo is a source artifact, ephemerals are reaped."
    exit 0
fi
echo "FAIL — see violations above."
echo
echo "Remedies:"
echo "  * move runtime dirs OUT of the checkout; point services at them by env var"
echo "  * agent-worktree-reaper.sh --archive DIR --reap"
echo "  * git worktree prune"
[ "$WARN_ONLY" = 1 ] && { echo "(--warn: not failing)"; exit 0; }
exit 1
