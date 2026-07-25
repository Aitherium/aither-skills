#!/usr/bin/env bash
# sumchain-node-up.sh — one command: nothing installed → a live SUM Chain devnet node.
#
# Brings a fresh Linux/WSL2 machine from zero to a running single-validator PoA
# SUM Chain node with OmniNode InferenceAttestation + Inference Settlement enabled
# from genesis (block 0):
#   1. install the Rust toolchain if missing (rustup, minimal),
#   2. clone + build the `sumchain` binary from the pinned upstream (wizzense/sum-chain),
#   3. materialize the devnet config (genesis + validator key + node.toml) with
#      real on-disk paths (the vendored config uses container /config,/data paths),
#   4. run the validator, and verify RPC :8545 is live AND blocks are being produced.
#
# The devnet config is injected by the caller as base64 env vars (SSOT stays in the
# AitherOS repo at AitherOS/external/sumchain-devnet/), so this script embeds no secrets.
#
# Usage (driven by AitherOS/scripts/omninode_sumchain_up.py — the sanctioned fleet tool):
#   SUMCHAIN_GENESIS_B64=... SUMCHAIN_VALKEY_B64=... SUMCHAIN_NODETOML_B64=... \
#     ./sumchain-node-up.sh [--run|--verify]
#
#   --verify  build + start + confirm RPC + block height >= 1, then LEAVE IT RUNNING (default)
#   --build   build only (no run)
#
# Env:
#   SUMCHAIN_REPO   upstream git URL (default https://github.com/wizzense/sum-chain.git)
#   SUMCHAIN_REF    pinned revision (default 6f08f5d3)
#   SUMCHAIN_HOME   install/state root (default $HOME/.sumchain)
#   SUMCHAIN_RPC_PORT  RPC bind port (default 8545)
#   SUMCHAIN_LISTEN_ADDR  overlay/host addr the RPC should advertise (default 0.0.0.0)
set -euo pipefail

REPO="${SUMCHAIN_REPO:-https://github.com/wizzense/sum-chain.git}"
REF="${SUMCHAIN_REF:-6f08f5d3}"
ROOT="${SUMCHAIN_HOME:-$HOME/.sumchain}"
RPC_PORT="${SUMCHAIN_RPC_PORT:-8545}"
MODE="${1:---verify}"

say() { printf '\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. toolchain ─────────────────────────────────────────────────────────────
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
  say "installing Rust toolchain (rustup, minimal)"
  curl -fsSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1 \
    || die "rustup install failed — see https://rustup.rs"
  source "$HOME/.cargo/env" 2>/dev/null || true
fi
command -v cargo >/dev/null 2>&1 || { source "$HOME/.cargo/env" 2>/dev/null || true; }
command -v cargo >/dev/null 2>&1 || die "cargo not on PATH after install"
_have_linker() { command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; }
# sum-chain deps (openssl-sys) need pkg-config + the openssl DEV package (headers +
# openssl.pc), which are NOT implied by a present C linker or the runtime libssl.so
# (the D-499 landmine). Detecting the runtime .so is not enough — openssl-sys needs the
# -dev package's openssl.pc. So: install the full native-build set UNCONDITIONALLY
# (idempotent) and then VERIFY pkg-config can actually resolve openssl before building.
export DEBIAN_FRONTEND=noninteractive
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig}"
# Full native-build set for the sum-chain workspace: a C toolchain + pkg-config +
# openssl DEV (openssl-sys) + clang/libclang (bindgen, used by zstd-sys/rocksdb-sys) +
# cmake (cmake-built native libs). Each was a real build failure in sequence; install
# the whole set up-front to avoid slow recompile round-trips.
PKGS="build-essential pkg-config libssl-dev clang libclang-dev cmake"
# Only apt-install if something is actually MISSING. A node that already has the full
# toolchain (e.g. the DGX: cc/pkg-config/openssl/clang/libclang/cmake all present) must
# NOT fail here just because apt is locked/offline — apt failure is non-fatal and the
# post-checks below are the real gate.
_missing=0
{ command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; } || _missing=1
command -v pkg-config >/dev/null 2>&1 || _missing=1
pkg-config --exists openssl 2>/dev/null || _missing=1
command -v cmake >/dev/null 2>&1 || _missing=1
{ find /usr/lib /usr/lib64 -name 'libclang.so*' 2>/dev/null | grep -q . \
  || command -v clang >/dev/null 2>&1; } || _missing=1
if [ "$_missing" = 1 ] && command -v apt-get >/dev/null 2>&1; then
  say "installing native build deps ($PKGS)"
  sudo -E apt-get update -qq >/dev/null 2>&1 || true
  sudo -E apt-get install -y -qq $PKGS >/dev/null 2>&1 \
    || sudo -E apt-get install -y $PKGS \
    || say "WARN: apt install failed; relying on already-present deps (post-checks gate)"
fi
_have_linker || die "no C linker found (need gcc/clang) and apt-get unavailable."
command -v pkg-config >/dev/null 2>&1 || die "pkg-config missing and could not be installed."
if ! pkg-config --exists openssl 2>/dev/null; then
  die "pkg-config cannot find openssl (libssl-dev not installed) — install libssl-dev and re-run."
fi
# bindgen (zstd-sys/rocksdb-sys) needs libclang.so on LIBCLANG_PATH.
# The `|| true` is REQUIRED: on nodes without /usr/lib64 (e.g. the aarch64 DGX) `find`
# exits non-zero, and with `set -o pipefail` + `set -e` the bare `_x=$(pipe)` assignment
# would inherit that and kill the script SILENTLY right here.
if [ -z "${LIBCLANG_PATH:-}" ]; then
  _libclang="$(find /usr/lib /usr/lib64 -name 'libclang.so*' 2>/dev/null | head -1 || true)"
  [ -n "$_libclang" ] && export LIBCLANG_PATH="$(dirname "$_libclang")"
fi
[ -n "${LIBCLANG_PATH:-}" ] || command -v clang >/dev/null 2>&1 \
  || die "libclang not found (install libclang-dev) — bindgen deps will fail."
echo "   openssl $(pkg-config --modversion openssl 2>/dev/null), clang $(clang --version 2>/dev/null | head -1), $(cargo --version)"

# ── 2. clone + build sumchain ────────────────────────────────────────────────
say "fetching SUM Chain ($REF)"
mkdir -p "$ROOT" && cd "$ROOT"
if [ ! -d src/.git ]; then git clone --quiet "$REPO" src; fi
cd src
git fetch --quiet origin 2>/dev/null || true
git checkout --quiet "$REF" 2>/dev/null || git checkout --quiet "origin/$REF" 2>/dev/null || true
echo "   revision $(git rev-parse --short HEAD)"

# rustls-only where a crate offers the choice (the fleet nodes have no openssl-sys/pkg
# native-tls path — this bit us on the snip-strata adapter, D-499). Harmless if unused.
export SUMCHAIN_REQWEST_RUSTLS=1

BIN="$ROOT/src/target/release/sumchain"
WAL="$ROOT/src/target/release/sumchain-wallet"
if [ ! -x "$BIN" ] || [ ! -x "$WAL" ]; then
  say "building sumchain + sumchain-wallet (release — first build compiles the full stack, ~10-20 min)"
  if ! cargo build --release --bin sumchain --bin sumchain-wallet 2>&1 | tail -40; then
    # Fallback: build the whole workspace, then locate the produced binary.
    say "retry: full workspace release build"
    cargo build --release 2>&1 | tail -40 || die "build failed — see cargo output above"
    BIN="$(find "$ROOT/src/target/release" -maxdepth 1 -type f -name 'sumchain' | head -1)"
    [ -n "$BIN" ] || BIN="$(find "$ROOT/src/target/release" -maxdepth 1 -type f -perm -u+x \
      ! -name '*.d' ! -name '*.so' | head -1)"
  fi
fi
[ -x "$BIN" ] || die "sumchain binary not found after build"
[ -x "$WAL" ] || echo "   WARN: sumchain-wallet not built (settlement proof needs it)"
echo "   binary: $BIN"
"$BIN" --version 2>/dev/null || "$BIN" --help 2>&1 | head -5 || true

if [ "$MODE" = "--build" ]; then
  printf '\033[32m== BUILD OK — sumchain compiled at %s\033[0m\n' "$BIN"
  exit 0
fi

# ── 3. materialize devnet config with real paths ─────────────────────────────
say "materializing devnet config"
CFG="$ROOT/config"; DATA="$ROOT/data"
# Genesis is regenerated each bring-up (fresh validator key), so any prior chain state in
# $DATA would mismatch the new genesis hash — wipe it (devnet state is disposable).
rm -rf "$DATA"
mkdir -p "$CFG" "$DATA"
[ -n "${SUMCHAIN_GENESIS_B64:-}" ]  || die "SUMCHAIN_GENESIS_B64 not provided (caller must inject the genesis)"
printf '%s' "$SUMCHAIN_GENESIS_B64" | base64 -d > "$CFG/dev_genesis.json"
python3 -c "import json;json.load(open('$CFG/dev_genesis.json'))" || die "genesis JSON did not parse"

# The vendored dev validator.key's pubkey format is rejected by this node build ("Invalid
# validator public key"). Generate a FRESH keypair with the node's own keygen and align
# genesis to it: validators[0] = its pubkey, and prefund its Address in alloc so the same
# key can later pay fees as the co-sign sponsor. Idempotent-ish: regenerated each bring-up
# (devnet state is disposable). The private key JSON lands at $CFG/validator.key.
say "generating validator keypair + aligning genesis"
"$BIN" keygen --output "$CFG/validator.key" > "$CFG/keygen.out" 2>&1 \
  || die "keygen failed: $(cat "$CFG/keygen.out" 2>/dev/null)"
VALPUB="$(sed -nE 's/^Public key:[[:space:]]*//p' "$CFG/keygen.out" | head -1 | tr -d ' \r')"
VALADDR="$(sed -nE 's/^Address:[[:space:]]*//p' "$CFG/keygen.out" | head -1 | tr -d ' \r')"
[ -n "$VALPUB" ] && [ -n "$VALADDR" ] || die "could not parse keygen output: $(cat "$CFG/keygen.out")"
python3 - "$CFG/dev_genesis.json" "$VALPUB" "$VALADDR" <<'PY' || die "genesis patch failed"
import json, sys
path, pub, addr = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
d["validators"] = [pub]
# The vendored alloc addresses are also format-rejected by this node build; REPLACE the
# whole alloc with just our freshly-generated (valid) sponsor address, funded 1e18.
d["alloc"] = {addr: 1000000000000000000}
# Enable SPONSORED (v2) inference attestations from genesis — the ACTA co-sign records
# node credits as sponsored attestations (sponsor pays, verifier signs). Without this the
# tx is included but fails execution: "sponsored inference attestation (v2) not enabled".
d.setdefault("params", {})["omninode_sponsored_attestation_enabled_from_height"] = 0
json.dump(d, open(path, "w"), indent=2)
print(f"   genesis validators[0]={pub}  funded alloc[{addr}]=1e18")
PY
echo "   validator pubkey: $VALPUB"
echo "   sponsor address (funded): $VALADDR"

# Node-local node.toml (real paths; RPC bound to all interfaces so mesh peers reach it).
cat > "$CFG/node.toml" <<TOML
[node]
genesis = "$CFG/dev_genesis.json"
data_dir = "$DATA"
validator_key = "$CFG/validator.key"

[consensus]
engine = "poa"

[network]
listen_addr = "/ip4/0.0.0.0/tcp/30303"
bootnodes = []
mdns = false
max_peers = 50

[rpc]
addr = "0.0.0.0:$RPC_PORT"
rate_limit_enabled = false

[logging]
level = "info"
json = false
TOML
echo "   config: $CFG/node.toml (rpc :$RPC_PORT, data $DATA)"

# ── 4. run + verify ──────────────────────────────────────────────────────────
say "starting SUM Chain validator"
pkill -f "sumchain run" 2>/dev/null || true
sleep 1
LOG="$ROOT/sumchain-run.log"
RUST_LOG="${RUST_LOG:-info}" nohup "$BIN" run --config "$CFG/node.toml" >"$LOG" 2>&1 &
NPID=$!
echo "   pid $NPID, log $LOG"

RPC="http://127.0.0.1:$RPC_PORT"
say "waiting for RPC + block production at $RPC"
height=""
for i in $(seq 1 60); do
  # health first
  curl -s --max-time 3 "$RPC/health" >/dev/null 2>&1 || curl -s --max-time 3 "$RPC/health/live" >/dev/null 2>&1 || true
  # sum_blockNumber returns a bare u64 (verified vs crates/rpc/src/api.rs); simpler
  # than chain_getBlockHeight, which returns a BlockHeightInfo{height,finality} object.
  resp="$(curl -s --max-time 4 -X POST "$RPC" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"sum_blockNumber","params":[]}' 2>/dev/null || true)"
  height="$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); r=d.get("result")
  print(r if isinstance(r,int) else (r.get("height") if isinstance(r,dict) else ""))
except Exception: print("")' 2>/dev/null || true)"
  if [ -n "$height" ] && [ "$height" -ge 1 ] 2>/dev/null; then break; fi
  if ! kill -0 "$NPID" 2>/dev/null; then
    echo "   --- node exited early; last log ---"; tail -30 "$LOG"; die "sumchain node exited during startup"
  fi
  sleep 3
done

if [ -n "$height" ] && [ "$height" -ge 1 ] 2>/dev/null; then
  printf '\033[32m== SUMCHAIN OK — validator live, RPC :%s, block height %s\033[0m\n' "$RPC_PORT" "$height"
  echo "   in-network callers: set AITHER_SUMCHAIN_RPC_URL=http://<node-overlay-ip>:$RPC_PORT"
  echo "   log: $LOG   stop: pkill -f 'sumchain run'"
  exit 0
else
  echo "   --- RPC never reported a block; last log ---"; tail -40 "$LOG"
  die "sumchain built + started but no block was produced (check consensus/validator key)"
fi
