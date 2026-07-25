#!/usr/bin/env bash
# sumchain-settle-proof.sh — prove the LIVE SUM Chain node actually settles transactions.
#
# Runs on the node where the chain is up (RPC localhost:8545, sponsor key + binaries under
# $SUMCHAIN_HOME). Proves the full settlement primitive end-to-end on the deployed chain:
#   1. block height is advancing (consensus is producing blocks),
#   2. the funded sponsor account has a balance,
#   3. a real value transfer sponsor -> fresh recipient is built + SIGNED + submitted +
#      FINALIZED (recipient balance goes from 0 to >0).
# This exercises the exact build->sign->submit->finalize path the ACTA co-sign will use.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
ROOT="${SUMCHAIN_HOME:-$HOME/.sumchain}"
RPC="${SUMCHAIN_RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${SUMCHAIN_CHAIN_ID:-1337}"
KEY="$ROOT/config/validator.key"
say() { printf '\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

BIN="$(find "$ROOT/src/target/release" -maxdepth 1 -type f -name sumchain 2>/dev/null | head -1)"
WAL="$(find "$ROOT/src/target/release" -maxdepth 1 -type f -name 'sumchain-wallet' 2>/dev/null | head -1)"
[ -x "$BIN" ] || die "sumchain binary not found under $ROOT"
[ -x "$WAL" ] || die "sumchain-wallet binary not found — rebuild with --bin sumchain-wallet"
[ -f "$KEY" ] || die "sponsor key not found at $KEY"

_rpc() { curl -s --max-time 6 -X POST "$RPC" -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}"; }
_num() { printf '%s' "$1" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); r=d.get("result")
  print(r if isinstance(r,int) else (r.get("height") if isinstance(r,dict) else ""))
except Exception: print("")'; }

say "1) block progression"
h1="$(_num "$(_rpc sum_blockNumber)")"; [ -n "$h1" ] || die "sum_blockNumber returned no height"
sleep 5
h2="$(_num "$(_rpc sum_blockNumber)")"; [ -n "$h2" ] || die "sum_blockNumber returned no height (2nd)"
echo "   height $h1 -> $h2"
[ "$h2" -gt "$h1" ] 2>/dev/null || die "chain not advancing ($h1 -> $h2)"

# derive the sponsor address from the key (keygen prints it; re-derive via wallet if needed)
SPONSOR="$(grep -aoE '"?[A-Za-z0-9]{30,50}"?' "$ROOT/config/keygen.out" 2>/dev/null | sed -n '2p' | tr -d '"')"
[ -n "$SPONSOR" ] || SPONSOR="$(sed -nE 's/^Address:[[:space:]]*//p' "$ROOT/config/keygen.out" 2>/dev/null | head -1 | tr -d ' \r')"
[ -n "$SPONSOR" ] || die "could not resolve sponsor address"
say "2) sponsor balance ($SPONSOR)"
"$WAL" balance --rpc "$RPC" --address "$SPONSOR" || die "sponsor balance query failed"

say "3) fresh recipient"
"$BIN" keygen --output "$ROOT/config/recipient.key" > "$ROOT/config/recipient.out" 2>&1 || die "recipient keygen failed"
RCPT="$(sed -nE 's/^Address:[[:space:]]*//p' "$ROOT/config/recipient.out" | head -1 | tr -d ' \r')"
[ -n "$RCPT" ] || die "could not parse recipient address"
echo "   recipient $RCPT"
bal_before="$("$WAL" balance --rpc "$RPC" --address "$RCPT" --raw 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)"
echo "   recipient balance before: ${bal_before:-0}"

say "4) transfer sponsor -> recipient (sign + send)"
"$WAL" transfer --key "$KEY" --rpc "$RPC" --to "$RCPT" --amount "1.0" --fee "0.001" --chain-id "$CHAIN_ID" -y \
  || die "transfer submit failed"

say "5) await finality (recipient balance > 0)"
ok=1
for i in $(seq 1 20); do
  sleep 3
  bal_after="$("$WAL" balance --rpc "$RPC" --address "$RCPT" --raw 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)"
  echo "   attempt $i: recipient balance ${bal_after:-0}"
  if [ -n "${bal_after:-}" ] && [ "${bal_after:-0}" -gt "${bal_before:-0}" ] 2>/dev/null; then ok=0; break; fi
done
[ "$ok" = 0 ] || die "transfer did not finalize (recipient balance never increased)"

printf '\033[32m== SETTLE PROOF OK — live SUM Chain finalized a signed value transfer (height %s->%s, recipient %s funded)\033[0m\n' "$h1" "$h2" "$RCPT"
echo "NODE OK"
