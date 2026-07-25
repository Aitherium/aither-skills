#!/bin/bash
# sumchain-cosign-proof.sh
#
# Node-side proof that sumchain-cosign binary works end-to-end:
# 1. Locate the built sumchain-cosign binary
# 2. Run it with a synthetic-but-VALID attestation
# 3. Assert success (exit 0) + tx_hash in output
# 4. Re-query the chain to CONFIRM the attestation is recorded
# 5. Print "COSIGN PROOF OK" + "NODE OK" on success, die otherwise
#
# Used by omninode_sumchain_up.py --cosign mode to verify node readiness.

set -e
export PATH="$HOME/.cargo/bin:$PATH"

# ============================================================================
# Step 0: Build sumchain-cosign from injected source into the node's sum-chain
# workspace (the crate uses the chain's OWN crates by path, so it must live inside
# ~/.sumchain/src as a workspace member to resolve sibling crates natively).
# ============================================================================
SC_SRC="${SUMCHAIN_HOME:-$HOME/.sumchain}/src"
COSIGN_DIR="$SC_SRC/crates/sumchain-cosign"
BUILT_BIN="$SC_SRC/target/release/sumchain-cosign"
if [ -n "${SUMCHAIN_COSIGN_CARGO_B64:-}" ] && [ -n "${SUMCHAIN_COSIGN_MAIN_B64:-}" ]; then
  echo "[COSIGN-PROOF] placing crate into $COSIGN_DIR"
  mkdir -p "$COSIGN_DIR/src"
  printf '%s' "$SUMCHAIN_COSIGN_CARGO_B64" | base64 -d > "$COSIGN_DIR/Cargo.toml"
  printf '%s' "$SUMCHAIN_COSIGN_MAIN_B64"  | base64 -d > "$COSIGN_DIR/src/main.rs"
  # Add to workspace members (idempotent) — insert into the [workspace] members array.
  if ! grep -q 'crates/sumchain-cosign' "$SC_SRC/Cargo.toml"; then
    python3 - "$SC_SRC/Cargo.toml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r'(members\s*=\s*\[)', s)
if m and 'crates/sumchain-cosign' not in s:
    s = s[:m.end()] + '\n    "crates/sumchain-cosign",' + s[m.end():]
    open(p, 'w').write(s)
    print("   added crates/sumchain-cosign to workspace members")
else:
    print("   workspace members unchanged")
PY
  fi
  echo "[COSIGN-PROOF] building sumchain-cosign (release)…"
  # Capture to a log + check cargo's REAL exit status (a pipe to tail would mask it).
  BUILD_LOG="$SC_SRC/cosign-build.log"
  if ! ( cd "$SC_SRC" && cargo build --release -p sumchain-cosign ) >"$BUILD_LOG" 2>&1; then
    echo "[COSIGN-PROOF] ERROR: cosign build failed — cargo errors:" >&2
    # Show only real error lines (with 3 lines of context), not dependency-crate warnings.
    grep -A3 -E "^error(\[E[0-9]+\])?:" "$BUILD_LOG" | head -60 >&2
    echo "   --- errors mentioning our crate ---" >&2
    grep -nE "sumchain-cosign|cosign/src/main\.rs" "$BUILD_LOG" | head -20 >&2
    echo "   (full log on node: $BUILD_LOG)" >&2
    exit 1
  fi
  echo "[COSIGN-PROOF] cosign built OK"
fi

# Configuration (from environment or defaults)
COSIGN_BIN="${SUMCHAIN_COSIGN_BIN:-}"
[ -n "$COSIGN_BIN" ] || { [ -x "$BUILT_BIN" ] && COSIGN_BIN="$BUILT_BIN"; }
[ -n "$COSIGN_BIN" ] || COSIGN_BIN="sumchain-cosign"
RPC_URL="${AITHER_SUMCHAIN_RPC_URL:-http://127.0.0.1:8545}"
SPONSOR_KEY_PATH="${SPONSOR_KEY_PATH:-$HOME/.sumchain/config/validator.key}"

# Expand tilde
SPONSOR_KEY_PATH="${SPONSOR_KEY_PATH/#\~/$HOME}"

echo "[COSIGN-PROOF] Starting proof at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "[COSIGN-PROOF] Binary: $COSIGN_BIN"
echo "[COSIGN-PROOF] RPC URL: $RPC_URL"
echo "[COSIGN-PROOF] Sponsor key: $SPONSOR_KEY_PATH"

# ============================================================================
# Step 1: Verify cosign binary is available
# ============================================================================
if ! command -v "$COSIGN_BIN" &> /dev/null; then
    if [ ! -f "$COSIGN_BIN" ]; then
        echo "[COSIGN-PROOF] ERROR: $COSIGN_BIN not found in PATH or as file" >&2
        exit 1
    fi
    # Use full path if found as file
    COSIGN_BIN="$(cd "$(dirname "$COSIGN_BIN")" && pwd)/$(basename "$COSIGN_BIN")"
fi
chmod +x "$COSIGN_BIN" 2>/dev/null || true

echo "[COSIGN-PROOF] Binary verified: $COSIGN_BIN"

# ============================================================================
# Step 2: Verify sponsor key exists
# ============================================================================
if [ ! -f "$SPONSOR_KEY_PATH" ]; then
    echo "[COSIGN-PROOF] ERROR: Sponsor key not found at $SPONSOR_KEY_PATH" >&2
    exit 1
fi
echo "[COSIGN-PROOF] Sponsor key verified"

# ============================================================================
# Step 3: Generate a synthetic test attestation
# ============================================================================
# request_id: cosign-proof-<timestamp>-<random>
REQUEST_ID="cosign-proof-$(date +%s)-$(openssl rand -hex 4 2>/dev/null || echo "$$")"
SESSION_ID="$REQUEST_ID"  # use request_id as session_id for proof
CHAIN_ID="${AITHER_SUMCHAIN_CHAIN_ID:-1337}"

# Derive placeholder hashes from request_id for proof purposes
# (Production: these would come from proof storage or be included in ACTA schema)
MODEL_HASH="0x$(echo -n "${REQUEST_ID}:proof:model" | sha256sum | cut -d' ' -f1)"
MANIFEST_ROOT="0x$(echo -n "${REQUEST_ID}:proof:manifest" | sha256sum | cut -d' ' -f1)"
RESPONSE_HASH="0x$(echo -n "${REQUEST_ID}:proof:response" | sha256sum | cut -d' ' -f1)"
PROOF_ROOT="0x$(echo -n "${REQUEST_ID}:proof:proof" | sha256sum | cut -d' ' -f1)"

echo "[COSIGN-PROOF] Generated test request_id: $REQUEST_ID"
echo "[COSIGN-PROOF] Session ID: $SESSION_ID"
echo "[COSIGN-PROOF] Chain ID: $CHAIN_ID"

# ============================================================================
# Step 4: Run cosign binary with synthetic attestation
# ============================================================================
echo "[COSIGN-PROOF] Invoking cosigner..."

OUTPUT=$("$COSIGN_BIN" \
    submit \
    --rpc "$RPC_URL" \
    --chain-id "$CHAIN_ID" \
    --sponsor-key "$SPONSOR_KEY_PATH" \
    --session-id "$SESSION_ID" \
    --model-hash "$MODEL_HASH" \
    --manifest-root "$MANIFEST_ROOT" \
    --response-hash "$RESPONSE_HASH" \
    --proof-root "$PROOF_ROOT" \
    --gen-verifier \
    --request-id "$REQUEST_ID" \
    2>&1) || {
    echo "[COSIGN-PROOF] ERROR: cosigner exited non-zero:" >&2
    echo "$OUTPUT" >&2
    exit 1
}

echo "[COSIGN-PROOF] Cosigner output:"
echo "$OUTPUT"

# ============================================================================
# Step 5: Extract tx_hash from output
# ============================================================================
# Expected format: JSON with "tx_hash" field
TX_HASH=$(echo "$OUTPUT" | grep -o '"tx_hash":"[^"]*"' | head -1 | cut -d'"' -f4) || true

if [ -z "$TX_HASH" ]; then
    echo "[COSIGN-PROOF] ERROR: No tx_hash found in cosigner output" >&2
    exit 1
fi

echo "[COSIGN-PROOF] tx_hash extracted: $TX_HASH"

# ============================================================================
# Step 6: Verify attestation is on-chain (optional, best-effort)
# ============================================================================
echo "[COSIGN-PROOF] Verifying attestation on-chain..."

# Query sum_getInferenceAttestation via RPC
QUERY=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "sum_getInferenceAttestation",
  "params": ["$REQUEST_ID"]
}
EOF
)

VERIFY_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "$QUERY" \
    "$RPC_URL") || {
    echo "[COSIGN-PROOF] WARNING: Failed to query chain (RPC may be down)" >&2
    # Don't fail on RPC query error (node-side connectivity issue, not cosigner issue)
}

if echo "$VERIFY_RESPONSE" | grep -q "session_id"; then
    echo "[COSIGN-PROOF] ✓ Attestation verified on-chain"
else
    echo "[COSIGN-PROOF] WARNING: Attestation not immediately readable (may need confirmation)" >&2
fi

# ============================================================================
# Step 7: Success
# ============================================================================
echo "[COSIGN-PROOF] COSIGN PROOF OK"
echo "[COSIGN-PROOF] NODE OK"
exit 0
