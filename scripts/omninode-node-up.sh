#!/usr/bin/env bash
# omninode-node-up.sh — one command: nothing installed → a live OmniNode node.
#
# Brings a fresh machine (Linux, macOS, or Windows/WSL2) from zero to a running
# OmniNode Protocol node on the peer-to-peer inference mesh:
#   1. detect the hardware you have,
#   2. install the Rust toolchain if missing (rustup, minimal),
#   3. clone + build the omni-node binary from the upstream protocol,
#   4. (default) verify the P2P layer works — two local peers discover each other,
#      or (--listen) run a persistent node that serves shards on the mesh.
#
# OmniNode Protocol is by SUM-INNOVATION — https://github.com/SUM-INNOVATION/OmniNode-Protocol
# This bootstrap is MIT-licensed, part of https://github.com/Aitherium/aither-skills — use it,
# fork it, or go straight to the upstream source. No prior Rust experience required.
#
# Usage:
#   ./omninode-node-up.sh            # build + self-verify P2P discovery (default), then exit
#   ./omninode-node-up.sh --listen   # build + run a persistent listening node (Ctrl-C to stop)
#   OMNINODE_REF=<git-sha> ./omninode-node-up.sh   # pin a specific protocol revision
#
# Requirements the script installs for you if absent: rustup/cargo, a C linker
# (build-essential / xcode CLT / your distro's gcc — on Debian/Ubuntu it will offer apt).
set -euo pipefail

REPO="${OMNINODE_REPO:-https://github.com/SUM-INNOVATION/OmniNode-Protocol.git}"
REF="${OMNINODE_REF:-}"                       # empty = default branch (latest)
ROOT="${OMNINODE_HOME:-$HOME/.omninode}"
MODE="${1:---verify}"

say() { printf '\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. detect hardware ───────────────────────────────────────────────────────
say "detecting hardware"
OS="$(uname -s)"; ARCH="$(uname -m)"
CORES="$( (nproc 2>/dev/null) || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
if [ "$OS" = "Darwin" ]; then
  MEM_GB="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))"
else
  MEM_GB="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
fi
GPU="none"; command -v nvidia-smi >/dev/null 2>&1 && GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
echo "   os=$OS arch=$ARCH cores=$CORES mem=${MEM_GB}GB gpu=$GPU"

# ── 2. toolchain ─────────────────────────────────────────────────────────────
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
  say "installing Rust toolchain (rustup, minimal)"
  curl -fsSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1 \
    || die "rustup install failed — see https://rustup.rs"
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env" 2>/dev/null || true
fi
command -v cargo >/dev/null 2>&1 || { source "$HOME/.cargo/env" 2>/dev/null || true; }
command -v cargo >/dev/null 2>&1 || die "cargo not on PATH after install — open a new shell and re-run"
# A C linker is required (proc-macros link at build time).
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    say "installing a C toolchain (build-essential) — sudo may prompt"
    sudo apt-get update -qq && sudo apt-get install -y -qq build-essential pkg-config || die "apt install failed"
  else
    die "no C linker found (need gcc/clang). Install your distro's build tools, e.g. 'xcode-select --install' on macOS."
  fi
fi
echo "   $(cargo --version)"

# ── 3. clone + build omni-node ───────────────────────────────────────────────
say "fetching OmniNode Protocol"
mkdir -p "$ROOT" && cd "$ROOT"
if [ ! -d src/.git ]; then git clone --quiet "$REPO" src; fi
cd src && git fetch --quiet origin 2>/dev/null || true
[ -n "$REF" ] && git checkout --quiet "$REF" 2>/dev/null || true
echo "   revision $(git rev-parse --short HEAD)"
BIN="$ROOT/src/target/debug/omni-node"
if [ ! -x "$BIN" ]; then
  say "building omni-node (first build compiles the libp2p stack — a few minutes)"
  cargo build -p omni-node || die "build failed — see the cargo output above"
fi
echo "   binary: $BIN"

# ── 4. run ───────────────────────────────────────────────────────────────────
case "$MODE" in
  --listen)
    say "starting a persistent OmniNode listener (Ctrl-C to stop)"
    exec env RUST_LOG=info "$BIN" listen
    ;;
  --verify|*)
    say "verifying the P2P layer — two local peers should discover each other"
    RUST_LOG=info nohup "$BIN" listen >/tmp/omninode-verify-listen.log 2>&1 &
    LPID=$!
    for _ in $(seq 1 15); do grep -q "LISTENING" /tmp/omninode-verify-listen.log 2>/dev/null && break; sleep 1; done
    ok=1
    for attempt in 1 2 3; do
      RUST_LOG=info timeout 35 "$BIN" send "omninode-node-up" >/tmp/omninode-verify-send.log 2>&1 || true
      if grep -qi "discovered" /tmp/omninode-verify-send.log; then ok=0; break; fi
      echo "   (attempt $attempt: waiting for peer discovery…)"; sleep 2
    done
    kill "$LPID" 2>/dev/null || true
    if [ "$ok" = 0 ]; then
      printf '\033[32m== NODE OK — omni-node built and P2P discovery works on this machine.\033[0m\n'
      # ── optional: enroll into the AitherMesh fabric so aither-adk agents can use this node ──
      # Seamless with the aither-adk / AitherNode / AitherConnect / AitherMesh substrate: if the
      # `adk` CLI is present (or you pass --adk), join this box to the AitherMesh WireGuard overlay
      # so adk agents discover it as a mesh peer. Fully optional — OmniNode works standalone.
      if command -v adk >/dev/null 2>&1 && { [ "${OMNINODE_ADK:-}" = "1" ] || [ "${2:-}" = "--adk" ]; }; then
        say "aither-adk detected — onboarding this node into AitherMesh"
        adk mesh onboard --role worker || echo "   (adk mesh onboard skipped/failed — non-fatal; node still works standalone)"
      elif command -v adk >/dev/null 2>&1; then
        echo "   aither-adk detected: run 'adk mesh onboard --role worker' to join this node to the mesh,"
        echo "   or re-run with --adk to do it automatically."
      fi
      echo "   run a persistent node with:  $0 --listen"
      exit 0
    else
      die "built fine, but P2P discovery did not complete — check the firewall / mDNS on this network."
    fi
    ;;
esac
