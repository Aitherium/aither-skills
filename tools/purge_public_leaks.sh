#!/usr/bin/env bash
# Purge leaked artifacts from a PUBLIC GitHub repo: pre-cutoff releases + tags,
# and (optionally) scrub a file out of the repo's entire git history.
#
# Fully parameterized — point it at any repo + leak path. Dry-run by default;
# the destructive steps are irreversible and outward-facing (they break pinned
# installs and existing clones/forks), so they need explicit flags.
#
# Usage:
#   purge_public_leaks.sh --repo OWNER/NAME [options]
#
# Options:
#   --repo OWNER/NAME        target GitHub repo (required)
#   --keep-from X.Y.Z        first clean version; version tags BELOW it (and
#                            their GitHub releases) are deleted. Omit to skip
#                            release/tag deletion entirely.
#   --tag-prefix PREFIX      version tag prefix (default: v). Tags must look like
#                            <prefix><semver>, e.g. v1.2.3.
#   --leak-path PATH         file to scrub from history (repeatable). Required
#                            for --rewrite-history.
#   --remote-url URL         override remote (default: https://github.com/OWNER/NAME.git)
#   --execute                actually delete releases + tags (otherwise dry-run)
#   --rewrite-history        with --execute: filter --leak-path out of ALL
#                            history and force-push a rewritten mirror
#
# Examples:
#   purge_public_leaks.sh --repo me/pkg --keep-from 2.0.0                 # plan
#   purge_public_leaks.sh --repo me/pkg --keep-from 2.0.0 --execute       # del releases/tags
#   purge_public_leaks.sh --repo me/pkg --leak-path src/secret.py \
#       --execute --rewrite-history                                        # scrub history
#
# Requires: gh (authenticated), git, and (for --rewrite-history) git-filter-repo.

set -euo pipefail

REPO=""
REMOTE_URL=""
KEEP_FROM=""
TAG_PREFIX="v"
LEAK_PATHS=()
EXECUTE=0
REWRITE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)             REPO="$2"; shift 2 ;;
    --remote-url)       REMOTE_URL="$2"; shift 2 ;;
    --keep-from)        KEEP_FROM="$2"; shift 2 ;;
    --tag-prefix)       TAG_PREFIX="$2"; shift 2 ;;
    --leak-path)        LEAK_PATHS+=("$2"); shift 2 ;;
    --execute)          EXECUTE=1; shift ;;
    --rewrite-history)  REWRITE=1; shift ;;
    -h|--help)          sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" ]] || { echo "ERROR: --repo OWNER/NAME is required." >&2; exit 2; }
REMOTE_URL="${REMOTE_URL:-https://github.com/${REPO}.git}"

note() { printf '\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

# Return 0 if dotted-numeric version $1 < $2. Non-numeric chunks compare as 0.
version_lt() {
  local a="${1#"$TAG_PREFIX"}" b="$2"
  local IFS=.
  read -ra A <<< "$a"; read -ra B <<< "$b"
  local i max=$(( ${#A[@]} > ${#B[@]} ? ${#A[@]} : ${#B[@]} ))
  for (( i=0; i<max; i++ )); do
    local x="${A[i]:-0}" y="${B[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    (( x < y )) && return 0
    (( x > y )) && return 1
  done
  return 1  # equal → not strictly less
}

note "== public leak purge (repo: ${REPO}) =="
[[ $EXECUTE -eq 0 ]] && warn "DRY RUN — nothing will be deleted. Add --execute to act."

# ---- 1 + 2: pre-cutoff releases & tags -------------------------------------
if [[ -n "$KEEP_FROM" ]]; then
  note ""
  note "[1/2] Releases + tags below ${KEEP_FROM} (prefix '${TAG_PREFIX}'):"
  mapfile -t TAGS < <(gh release list --repo "$REPO" --limit 500 \
                        --json tagName --jq '.[].tagName' 2>/dev/null || true)
  TARGETS=()
  for tag in "${TAGS[@]:-}"; do
    [[ "$tag" == "${TAG_PREFIX}"[0-9]* ]] || continue   # only version tags
    if version_lt "$tag" "$KEEP_FROM"; then TARGETS+=("$tag"); fi
  done

  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    note "  (none found)"
  else
    printf '  %s\n' "${TARGETS[@]}"
    if [[ $EXECUTE -eq 1 ]]; then
      for tag in "${TARGETS[@]}"; do
        note "  deleting release+tag $tag ..."
        gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag \
          || warn "  (release delete failed for $tag — may be tag-only)"
        git push "$REMOTE_URL" --delete "$tag" 2>/dev/null || true
      done
    fi
  fi
else
  note ""
  note "[1/2] release/tag deletion skipped (no --keep-from given)."
fi

# ---- 3: history scrub ------------------------------------------------------
note ""
note "[2/2] Scrub leak path(s) from repo history:"
if [[ ${#LEAK_PATHS[@]} -eq 0 ]]; then
  note "  (no --leak-path given — nothing to scrub)"
elif [[ $REWRITE -eq 1 && $EXECUTE -eq 1 ]]; then
  command -v git-filter-repo >/dev/null 2>&1 || {
    warn "  git-filter-repo not installed: pip install git-filter-repo"; exit 3; }
  WORK="$(mktemp -d)"
  note "  cloning a fresh mirror into $WORK (a clean mirror carries no local"
  note "  pre-push hooks, so it can force-push) ..."
  git clone --mirror "$REMOTE_URL" "$WORK/repo.git"
  (
    cd "$WORK/repo.git"
    FILTER_ARGS=()
    for p in "${LEAK_PATHS[@]}"; do FILTER_ARGS+=(--path "$p"); done
    git filter-repo --force --invert-paths "${FILTER_ARGS[@]}"

    # Drop pre-cutoff version tags too, if a cutoff was given.
    if [[ -n "$KEEP_FROM" ]]; then
      for tag in $(git tag); do
        [[ "$tag" == "${TAG_PREFIX}"[0-9]* ]] || continue
        if version_lt "$tag" "$KEEP_FROM"; then git tag -d "$tag" >/dev/null; fi
      done
    fi

    # Verify every leak path is gone from ALL history before the irreversible push.
    for p in "${LEAK_PATHS[@]}"; do
      if [[ -n "$(git log --all --oneline -- "$p")" ]]; then
        warn "  ABORT: '$p' still present in history after filter — not pushing."
        exit 4
      fi
    done
    note "  verified: leak path(s) absent from all history; $(git rev-list --count --all) commits remain."
    warn "  FORCE-PUSHING rewritten history + tag deletions (IRREVERSIBLE) ..."
    git push --force --mirror "$REMOTE_URL"
  )
  rm -rf "$WORK"
  note "  history scrub complete."
else
  warn "  skipped (needs --execute --rewrite-history)."
  warn "  Manual equivalent:"
  echo  "    git clone --mirror $REMOTE_URL && cd repo.git"
  for p in "${LEAK_PATHS[@]}"; do
    echo  "    git filter-repo --invert-paths --path $p"
  done
  echo  "    git push --force --mirror $REMOTE_URL"
fi

note ""
warn "REMINDER: code already installed/cloned/forked cannot be truly un-published."
warn "This reduces exposure; it is NOT erasure. If any removed file carried"
warn "secrets, rotate them NOW."
