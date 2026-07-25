#!/usr/bin/env bash
# sumchain-cosign-submit.sh — REAL on-chain co-sign of ONE ACTA settled_local row.
#
# Node-side: builds sumchain-cosign from injected source (if needed), ensures a
# PERSISTENT verifier identity key for this node (the serving node IS the verifier —
# not a throwaway --gen-verifier), then submits the InferenceAttestation for a REAL
# credit using the REAL request_id + REAL hashes captured at inference time, and prints
# the cosign JSON result ({"ok":true,"tx_hash":...}) on stdout for the controller driver.
#
# Injected env (by the driver via the fleet transport):
#   SUMCHAIN_COSIGN_CARGO_B64 / SUMCHAIN_COSIGN_MAIN_B64  crate source (build if needed)
#   COSIGN_REQUEST_ID   the ACTA row's real request_id (idempotency key)
#   COSIGN_SESSION_ID   session id (= request_id)
#   COSIGN_MODEL_HASH / COSIGN_MANIFEST_ROOT / COSIGN_RESPONSE_HASH / COSIGN_PROOF_ROOT
#                       the REAL 0x-hashes from the served inference
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
SC_SRC="${SUMCHAIN_HOME:-$HOME/.sumchain}/src"
CFG="${SUMCHAIN_HOME:-$HOME/.sumchain}/config"
RPC="${AITHER_SUMCHAIN_RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${AITHER_SUMCHAIN_CHAIN_ID:-1337}"
SPONSOR_KEY="$CFG/validator.key"
VERIFIER_KEY="$CFG/verifier.key"
COSIGN_DIR="$SC_SRC/crates/sumchain-cosign"
BUILT_BIN="$SC_SRC/target/release/sumchain-cosign"

emit() { printf '[COSIGN-SUBMIT] %s\n' "$*" >&2; }

for v in COSIGN_REQUEST_ID COSIGN_RESPONSE_HASH; do
  [ -n "${!v:-}" ] || { emit "ERROR: $v not provided"; exit 1; }
done

# --- build cosign from injected source if the binary is missing ---
if [ ! -x "$BUILT_BIN" ] && [ -n "${SUMCHAIN_COSIGN_CARGO_B64:-}" ]; then
  emit "building sumchain-cosign into $COSIGN_DIR"
  mkdir -p "$COSIGN_DIR/src"
  printf '%s' "$SUMCHAIN_COSIGN_CARGO_B64" | base64 -d > "$COSIGN_DIR/Cargo.toml"
  printf '%s' "$SUMCHAIN_COSIGN_MAIN_B64"  | base64 -d > "$COSIGN_DIR/src/main.rs"
  if ! grep -q 'crates/sumchain-cosign' "$SC_SRC/Cargo.toml"; then
    python3 - "$SC_SRC/Cargo.toml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r'(members\s*=\s*\[)', s)
if m and 'crates/sumchain-cosign' not in s:
    open(p, 'w').write(s[:m.end()] + '\n    "crates/sumchain-cosign",' + s[m.end():])
PY
  fi
  ( cd "$SC_SRC" && cargo build --release -p sumchain-cosign ) >"$SC_SRC/cosign-build.log" 2>&1 \
    || { emit "ERROR: cosign build failed"; grep -A3 -E '^error' "$SC_SRC/cosign-build.log" | head -40 >&2; exit 1; }
fi
[ -x "$BUILT_BIN" ] || { emit "ERROR: sumchain-cosign binary missing"; exit 1; }
[ -f "$SPONSOR_KEY" ] || { emit "ERROR: sponsor key missing ($SPONSOR_KEY)"; exit 1; }

# --- persistent verifier identity for THIS node (generate once, reuse) ---
if [ ! -f "$VERIFIER_KEY" ]; then
  emit "generating persistent node verifier key ($VERIFIER_KEY)"
  "$BUILT_BIN" --help >/dev/null 2>&1 || true
  # Use the chain's keygen (same JSON seed format the cosign load_keypair parses).
  SC_BIN="$(find "$SC_SRC/target/release" -maxdepth 1 -type f -name sumchain 2>/dev/null | head -1 || true)"
  [ -x "$SC_BIN" ] || { emit "ERROR: sumchain binary missing for keygen"; exit 1; }
  "$SC_BIN" keygen --output "$VERIFIER_KEY" >/dev/null 2>&1 \
    || { emit "ERROR: verifier keygen failed"; exit 1; }
fi

MODEL_HASH="${COSIGN_MODEL_HASH:-0x$(printf '%064d' 0)}"
MANIFEST_ROOT="${COSIGN_MANIFEST_ROOT:-0x$(printf '%064d' 0)}"
PROOF_ROOT="${COSIGN_PROOF_ROOT:-0x$(printf '%064d' 0)}"
SESSION_ID="${COSIGN_SESSION_ID:-$COSIGN_REQUEST_ID}"

emit "submitting REAL attestation: request_id=$COSIGN_REQUEST_ID response_hash=$COSIGN_RESPONSE_HASH"
# REAL submit: persistent --verifier-key (NOT --gen-verifier), real request_id + hashes.
OUT="$("$BUILT_BIN" submit \
  --rpc "$RPC" --chain-id "$CHAIN_ID" \
  --sponsor-key "$SPONSOR_KEY" --verifier-key "$VERIFIER_KEY" \
  --session-id "$SESSION_ID" \
  --model-hash "$MODEL_HASH" --manifest-root "$MANIFEST_ROOT" \
  --response-hash "$COSIGN_RESPONSE_HASH" --proof-root "$PROOF_ROOT" \
  --request-id "$COSIGN_REQUEST_ID" 2>>/dev/stderr)" || { emit "ERROR: cosign submit failed"; exit 1; }

# --- FINALITY GATE (reorg-safety) ---------------------------------------------
# The cosign binary returns a tx_hash once the attestation is INCLUDED. Inclusion
# is not finality: a reorg can drop an included block. So we poll the chain for
# {"kind":"finalized"} and emit an authoritative result line carrying BOTH the
# tx_hash AND finalized. Fail-CLOSED: unless the chain positively confirms
# finalized, we emit finalized=false and the controller leaves the ACTA row
# settled_local for a later reconcile pass (it never flips onchain on a tx that
# merely got included, or that later reverted).
emit "cosign raw: $OUT"
TX="$(printf '%s' "$OUT" | grep -o '"tx_hash"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/' || true)"
if [ -z "$TX" ]; then
  emit "ERROR: no tx_hash in cosign output"
  exit 1
fi
emit "submitted tx=$TX; polling chain_getTransactionStatus for finality"
FINALIZED=false
_tries="${COSIGN_FINALITY_TRIES:-30}"
_sleep="${COSIGN_FINALITY_SLEEP:-2}"
_i=0
while [ "$_i" -lt "$_tries" ]; do
  _i=$((_i + 1))
  ST="$(curl -s --max-time 5 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"chain_getTransactionStatus\",\"params\":[\"$TX\"]}" \
        "$RPC" 2>/dev/null || true)"
  case "$ST" in
    *'"kind":"finalized"'*) FINALIZED=true; break ;;
    *'"kind":"failed"'*)    emit "tx $TX reported FAILED on-chain"; break ;;
  esac
  sleep "$_sleep"
done
# Authoritative result line for the driver (the ONLY line on stdout): carries the
# tx_hash and the finality verdict together.
printf '{"ok":true,"tx_hash":"%s","finalized":%s}\n' "$TX" "$FINALIZED"
emit "done (tx=$TX finalized=$FINALIZED)"
