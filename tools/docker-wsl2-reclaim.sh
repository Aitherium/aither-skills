#!/usr/bin/env bash
# docker-wsl2-reclaim.sh — diagnose and reclaim a bloated Docker Desktop VHDX on WSL2.
#
# THE PROBLEM
# -----------
# Docker Desktop on WSL2 keeps its images/volumes in a dynamically-expanding VHDX.
# That file GROWS and never shrinks on its own, because Docker's data disk is
# mounted WITHOUT the `discard` option:
#
#   /dev/sdd on /mnt/docker-desktop-disk type ext4 (rw,relatime)   <-- no discard
#
# Delete a 40GB image and ext4 marks the blocks free, but nothing tells the VHDX,
# so the host file stays exactly as large as its all-time high-water mark.
#
# THREE LAYERS OF ACCOUNTING, EACH HIDING THE NEXT
# ------------------------------------------------
#   VHDX allocated on the host   >=   ext4 "used" inside the VM   >=   docker system df
#
# Measured on a real box (2026-07-25):
#   VHDX allocated .......... 2.0 TB    <- what Windows sees; what fills your drive
#   ext4 used ............... 1.6 TB    <- what the guest filesystem thinks it holds
#   docker system df ........ 634 GB    <- what Docker admits to
#
# `docker system df` is the number people look at, and it is the LEAST relevant of
# the three. Reclaiming works from the bottom up: prune (shrinks docker's number),
# fstrim (turns ext4's free blocks into VHDX-visible holes), compact (shrinks the
# host file). Skip fstrim and compaction reclaims almost nothing.
#
# Usage:
#   docker-wsl2-reclaim.sh              # diagnose only — safe, read-only
#   docker-wsl2-reclaim.sh --trim       # prune + fstrim (no downtime, no admin)
#   docker-wsl2-reclaim.sh --plan       # print the admin compaction recipe
#
# Compaction itself is NOT done here: it needs the VM shut down AND administrator,
# so it cannot be made safe to run unattended from inside a session. --plan prints
# the exact commands.

set -uo pipefail
MODE="${1:-diagnose}"
DISTRO="${DOCKER_WSL_DISTRO:-docker-desktop}"
DATA_MNT="${DOCKER_WSL_DATA_MNT:-/mnt/docker-desktop-disk}"

_wsl() { wsl.exe -d "$DISTRO" -e sh -c "$1" 2>/dev/null | tr -d '\r'; }

find_vhdx() {
    # Docker Desktop's data disk. Location follows the "Disk image location"
    # setting, so probe the usual spots rather than assuming.
    # `set -u` is on and neither LOCALAPPDATA nor USER is guaranteed to exist in
    # a Git-Bash / CI shell — dereferencing them bare aborts the whole script
    # before it can report anything. Default them, then skip empty candidates.
    local c lad="${LOCALAPPDATA:-}" who="${USER:-${USERNAME:-}}"
    for c in \
        "${lad:+$lad/Docker/wsl/disk/docker_data.vhdx}" \
        "${lad:+$lad/Docker/wsl/data/ext4.vhdx}" \
        "${who:+/c/Users/$who/AppData/Local/Docker/wsl/disk/docker_data.vhdx}"
    do
        [ -n "$c" ] || continue
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    # Fall back to a scan of common data roots (cheap: maxdepth 4).
    for root in /c /d /e /f /g; do
        [ -d "$root" ] || continue
        c="$(find "$root" -maxdepth 5 \( -name 'docker_data.vhdx' -o -name 'ext4.vhdx' \) 2>/dev/null              | xargs -r ls -S 2>/dev/null | head -1)"
        [ -n "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

diagnose() {
    echo "=== LAYER 1: VHDX as the host sees it ==="
    local v; v="$(find_vhdx)"
    if [ -n "$v" ]; then
        echo "  path      : $v"
        echo "  apparent  : $(ls -la "$v" 2>/dev/null | awk '{printf "%.1f GB", $5/1073741824}')"
        echo "  allocated : $(du -h "$v" 2>/dev/null | cut -f1)"
    else
        echo "  (vhdx not located — set DOCKER_WSL_VHDX or check Settings > Resources)"
    fi

    echo
    echo "=== LAYER 2: ext4 inside the VM (the number that actually matters) ==="
    _wsl "df -h $DATA_MNT | tail -1" | sed 's/^/  /'
    echo "  mount opts: $(_wsl "mount | grep ' $DATA_MNT ' | head -1 | sed 's/.*type //'")"
    if ! _wsl "mount | grep ' $DATA_MNT ' | head -1" | grep -q discard; then
        echo "  ^^ NO 'discard' — freed blocks are never returned to the VHDX."
        echo "     This is why the file only ever grows. fstrim is mandatory."
    fi

    echo
    echo "=== LAYER 3: what Docker admits to ==="
    docker system df 2>/dev/null | tail -5 | sed 's/^/  /'

    echo
    echo "The gap between LAYER 2 and LAYER 3 is deleted-but-untrimmed data."
    echo "The gap between LAYER 1 and LAYER 2 is what compaction will reclaim."
}

do_trim() {
    echo ">>> pruning dangling images + build cache (safe: never touches running containers)"
    docker image prune -f 2>&1 | tail -1
    docker builder prune -af 2>&1 | tail -1

    echo ">>> fstrim on $DATA_MNT (can take several minutes)"
    _wsl "df -h $DATA_MNT | tail -1" | sed 's/^/  before: /'
    _wsl "fstrim -v $DATA_MNT" | sed 's/^/  /'
    _wsl "df -h $DATA_MNT | tail -1" | sed 's/^/  after:  /'

    echo
    echo ">>> fstrim only frees what ext4 KNOWS is free. If the trimmed number is"
    echo "    small but ext4 'used' is still far above 'docker system df', the space"
    echo "    is live data Docker under-reports (orphaned overlay2 layers, buildkit"
    echo "    state, container logs) — not something a prune will find."
    echo ">>> run with --plan for the compaction step that shrinks the host file."
}

print_plan() {
    local v win
    v="$(find_vhdx)"
    # Build the Windows path OUTSIDE the heredoc. An unquoted heredoc re-processes
    # backslashes, which silently doubled every separator and produced a path
    # diskpart rejects (`Local\\Docker\\wsl\\`). Convert once, interpolate once.
    if [ -n "$v" ]; then
        win="$(printf '%s' "$v" | sed -e 's|^/\([a-zA-Z]\)/|\1:/|' -e 's|/|\\|g')"
        # /c/... -> C:\...  and already-Windows paths keep their drive letter.
        win="$(printf '%s' "$win" | sed -e 's|^\([a-z]\):|\U\1:|')"
    else
        win='<path-to>\docker_data.vhdx'
    fi
    cat <<EOF

=== COMPACTION (requires ADMINISTRATOR and a stopped VM) ===

Do the --trim step FIRST, or this reclaims almost nothing.

  1. Quit Docker Desktop from the tray, then:
       wsl --shutdown

  2. Elevated PowerShell. Prefer diskpart — Optimize-VHD gives no progress output
     and on a multi-TB file looks indistinguishable from a hang:

       diskpart
         select vdisk file="$win"
         attach vdisk readonly
         compact vdisk
         detach vdisk
         exit

     diskpart prints a percentage; Optimize-VHD does not. If you prefer it:
       Optimize-VHD -Path "..." -Mode Full

  3. Start Docker Desktop and confirm the fleet returns.

PREVENTING THE REGROWTH
  - schedule the --trim step (weekly is plenty)
  - .wslconfig: [experimental] sparseVhd=true   (NEW disks only — it does not
    retro-fit an already-allocated VHDX, which is why yours stayed 2TB)
  - never bulk-build with the fleet resident: that is a separate failure mode
    that crashes the WSL2 backend entirely — see docker-wsl2-build-safety

EOF
}

case "$MODE" in
    diagnose|"") diagnose ;;
    --trim)      diagnose; echo; do_trim ;;
    --plan)      print_plan ;;
    *) echo "usage: $0 [--trim|--plan]" >&2; exit 2 ;;
esac
