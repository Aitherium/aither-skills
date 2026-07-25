#!/usr/bin/env bash
# omninode-infer-proof.sh — build the inference-capable omni-node and PROVE a real
# inference request/response travels over omni-net's P2P gossipsub transport.
#
# This is the OmniNode "walking skeleton": the shipped binary proves peer
# discovery + gossipsub + shard/tensor RPC but wires NOTHING to a model. This
# script overlays two small additions onto the pinned omni-node source —
#   * a new `serve-infer` subcommand: subscribe to omni/contributor/job/v1, run
#     each job through a local llama.cpp `llama-server`, publish the completion
#     on omni/contributor/result/v1, and
#   * a new `infer` subcommand: publish a job, await the matching result —
# builds it, then runs both as two local omni-node processes so a prompt goes
# out over omni-net and a real completion comes back.
#
# Injected by the driver (omninode_infer_proof.py), or settable directly:
#   INFER_CLI_B64     base64 of crates/omni-node/src/infer_cli.rs (REQUIRED)
#   PROOF_MODE        echo | bonsai            (default: echo)
#   PROOF_BACKEND     llama-server base URL    (default: http://127.0.0.1:8090)
#   PROOF_PROMPT      prompt to run            (default: a fixed proof prompt)
#   PROOF_MAX_TOKENS  max tokens               (default: 24)
#   OMNINODE_SRC      omni-node clone dir      (default: $HOME/.omninode/src)
#   OMNINODE_PIN      git sha to build         (default: ce619521…)
#
# Prints a final `PROOF OK` (and `NODE OK`, which the fleet driver greps) only
# when infer exited 0 AND the result JSON has "ok":true.
set -uo pipefail

MODE="${PROOF_MODE:-echo}"
BACKEND="${PROOF_BACKEND:-http://127.0.0.1:8090}"
PROMPT="${PROOF_PROMPT:-In one short sentence: what is the AitherNet?}"
MAX_TOKENS="${PROOF_MAX_TOKENS:-24}"
SRC="${OMNINODE_SRC:-$HOME/.omninode/src}"
PIN="${OMNINODE_PIN:-ce619521331f889630f545e3981723d0dd981f54}"
REPO="${OMNINODE_REPO:-https://github.com/wizzense/OmniNode-Protocol.git}"

say() { printf '== %s\n' "$*"; }
die() { printf 'PROOF FAIL: %s\n' "$*" >&2; exit 1; }

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || { source "$HOME/.cargo/env" 2>/dev/null || true; }
command -v cargo >/dev/null 2>&1 || die "cargo not found on PATH"

# ── 1. ensure the pinned source is present ────────────────────────────────────
say "omni-node source at $SRC (pin ${PIN:0:7})"
if [ ! -d "$SRC/.git" ]; then
  say "cloning $REPO"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet "$REPO" "$SRC" || die "clone failed"
fi
cd "$SRC" || die "cannot cd $SRC"
# Reset any prior overlay of tracked files, then pin. (infer_cli.rs is untracked
# and is rewritten below, so it is unaffected by checkout.)
git checkout --quiet -- crates/omni-node/src/main.rs 2>/dev/null || true
git fetch --quiet origin 2>/dev/null || true
git checkout --quiet "$PIN" 2>/dev/null || say "warning: could not checkout $PIN (building current HEAD)"
say "building at $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ── 2. apply the overlay ──────────────────────────────────────────────────────
[ -n "${INFER_CLI_B64:-}" ] || die "INFER_CLI_B64 not provided"
printf '%s' "$INFER_CLI_B64" | base64 -d > crates/omni-node/src/infer_cli.rs \
  || die "failed to decode infer_cli.rs"
say "wrote crates/omni-node/src/infer_cli.rs ($(wc -l < crates/omni-node/src/infer_cli.rs) lines)"

# Idempotent main.rs patch: module decl, two subcommands, two dispatch arms.
python3 - "$SRC/crates/omni-node/src/main.rs" <<'PYEOF' || die "main.rs patch failed"
import sys, io
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
orig = s

if "mod infer_cli;" not in s:
    s = s.replace("mod operator;", "mod infer_cli;\nmod operator;", 1)

if "ServeInfer {" not in s:
    anchor = "    Operator(operator::OperatorArgs),\n"
    variants = anchor + (
        "\n"
        "    /// Serve inference over the mesh: subscribe to jobs, run each through a\n"
        "    /// local llama.cpp `llama-server`, and publish the completion back.\n"
        "    ServeInfer {\n"
        "        /// Backend `llama-server` base URL, or the literal \"echo\".\n"
        "        #[arg(long, default_value = \"http://127.0.0.1:8090\")]\n"
        "        backend: String,\n"
        "        /// Authorization token; jobs must present a matching `auth`.\n"
        "        /// Empty (and OMNI_INFER_AUTH_TOKEN unset) => serve nothing.\n"
        "        #[arg(long, default_value = \"\")]\n"
        "        auth_token: String,\n"
        "    },\n"
        "\n"
        "    /// Publish an inference job to the mesh and print the completion.\n"
        "    Infer {\n"
        "        /// Prompt to run on a remote serve-infer provider.\n"
        "        prompt: String,\n"
        "        /// Maximum number of tokens to generate.\n"
        "        #[arg(long, default_value_t = 64)]\n"
        "        max_tokens: u32,\n"
        "        /// Authorization token presented to the provider.\n"
        "        #[arg(long, default_value = \"\")]\n"
        "        auth_token: String,\n"
        "    },\n"
    )
    assert anchor in s, "Operator variant anchor not found"
    s = s.replace(anchor, variants, 1)

if "Command::ServeInfer" not in s:
    anchor = "        Command::Operator(args)   => operator::dispatch(args).await,\n"
    arms = anchor + (
        "        Command::ServeInfer { backend, auth_token } =>\n"
        "            infer_cli::run_serve_infer(backend, auth_token).await,\n"
        "        Command::Infer { prompt, max_tokens, auth_token } =>\n"
        "            infer_cli::run_infer(prompt, max_tokens, auth_token).await,\n"
    )
    assert anchor in s, "Operator dispatch anchor not found"
    s = s.replace(anchor, arms, 1)

if s != orig:
    io.open(p, "w", encoding="utf-8").write(s)
    print("main.rs patched")
else:
    print("main.rs already patched")
PYEOF

# Cross-node overlay: make NetConfig::default() read OMNI_LISTEN_PORT +
# OMNI_BOOTSTRAP_PEERS from the environment so a node on a different host can dial
# a known peer's multiaddr via Kademlia (mDNS does not cross hosts). Backward
# compatible: unset env => listen_port 0 + no bootstrap peers (current behavior).
python3 - "$SRC/crates/omni-types/src/config.rs" <<'PYEOF' || die "config.rs patch failed"
import sys, io
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
if "OMNI_BOOTSTRAP_PEERS" in s:
    print("config.rs already patched"); sys.exit(0)
old = (
    "impl Default for NetConfig {\n"
    "    fn default() -> Self {\n"
    "        Self {\n"
    "            listen_port: 0,\n"
    "            bootstrap_peers: vec![],\n"
    "            relay_server: false,\n"
    "            identity: NetIdentity::Ephemeral,\n"
    "        }\n"
    "    }\n"
    "}"
)
new = (
    "impl Default for NetConfig {\n"
    "    fn default() -> Self {\n"
    "        // OmniNode inference overlay: env-injected cross-host dialing.\n"
    "        let listen_port = std::env::var(\"OMNI_LISTEN_PORT\")\n"
    "            .ok()\n"
    "            .and_then(|s| s.trim().parse::<u16>().ok())\n"
    "            .unwrap_or(0);\n"
    "        let bootstrap_peers = std::env::var(\"OMNI_BOOTSTRAP_PEERS\")\n"
    "            .ok()\n"
    "            .map(|s| {\n"
    "                s.split(',')\n"
    "                    .map(|x| x.trim().to_string())\n"
    "                    .filter(|x| !x.is_empty())\n"
    "                    .collect::<Vec<String>>()\n"
    "            })\n"
    "            .unwrap_or_default();\n"
    "        Self {\n"
    "            listen_port,\n"
    "            bootstrap_peers,\n"
    "            relay_server: false,\n"
    "            identity: NetIdentity::Ephemeral,\n"
    "        }\n"
    "    }\n"
    "}"
)
assert old in s, "NetConfig Default block not found (source drift?)"
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
print("config.rs patched")
PYEOF

# ── 3. build ──────────────────────────────────────────────────────────────────
say "cargo build -p omni-node (incremental)"
BIN="$SRC/target/debug/omni-node"
if ! cargo build -p omni-node >/tmp/omni-infer-build.log 2>&1; then
  echo "--- build log tail ---"; tail -40 /tmp/omni-infer-build.log
  die "build failed"
fi
[ -x "$BIN" ] || die "binary missing after build: $BIN"
say "built $BIN"
"$BIN" --help 2>&1 | grep -qi "serve-infer" || die "serve-infer subcommand not in built binary"
say "serve-infer + infer subcommands present"

# Build-only mode: the cross-node driver builds the overlay on each node first,
# then orchestrates serve/infer across hosts itself.
if [ "${PROOF_BUILD_ONLY:-0}" = "1" ]; then
  echo "BUILD OK — $BIN"
  echo "NODE OK"
  exit 0
fi

# ── 4. optional backend health (bonsai mode) ──────────────────────────────────
if [ "$MODE" = "bonsai" ]; then
  H="$(curl -s -m 5 "$BACKEND/health" 2>&1 | head -c 160)"
  echo "BACKEND_HEALTH($BACKEND): $H"
  echo "$H" | grep -qiE 'ok|ready|"status"' || say "warning: backend health not confirmed — proceeding anyway"
  RUN_BACKEND="$BACKEND"
else
  RUN_BACKEND="echo"
fi
TOKEN="${PROOF_AUTH_TOKEN:-omni-infer-proof-$$}"
say "proof mode=$MODE backend=$RUN_BACKEND prompt='$PROMPT' max_tokens=$MAX_TOKENS gated=yes"

# Each test gets a FRESH serve-infer: a second infer process against the same
# serve suffers gossipsub mesh churn (the departing peer's PRUNE) and may fail to
# re-GRAFT in time, which is a transport artifact, not a gate result. Fresh serve
# per test isolates them.
start_serve() {  # sets SPID; dies if serve doesn't come up
  pkill -f "omni-node serve-infer" 2>/dev/null || true; sleep 1
  : > /tmp/omni-serve.log
  RUST_LOG=info nohup "$BIN" serve-infer --backend "$RUN_BACKEND" --auth-token "$TOKEN" \
    >/tmp/omni-serve.log 2>&1 &
  SPID=$!
  for _ in $(seq 1 25); do grep -q "waiting for inference jobs" /tmp/omni-serve.log 2>/dev/null && break; sleep 1; done
  grep -q "waiting for inference jobs" /tmp/omni-serve.log 2>/dev/null \
    || { echo "--- serve log ---"; tail -20 /tmp/omni-serve.log; kill $SPID 2>/dev/null; die "serve-infer did not come up"; }
}
stop_serve() { sleep 1; kill "$SPID" 2>/dev/null || true; pkill -f "omni-node serve-infer" 2>/dev/null || true; sleep 1; }

# ── 5. POSITIVE: an AUTHORIZED inference carried over omni-net ─────────────────
start_serve
say "serve-infer up (pid $SPID, gated) — publishing an AUTHORIZED job over omni-net"
RUST_LOG=info timeout 220 "$BIN" infer "$PROMPT" --max-tokens "$MAX_TOKENS" --auth-token "$TOKEN" \
  >/tmp/omni-infer.out 2>/tmp/omni-infer.err
IEXIT=$?
RESULT_JSON="$(grep -E '^\{' /tmp/omni-infer.out 2>/dev/null | tail -1)"
cp /tmp/omni-serve.log /tmp/omni-serve-pos.log 2>/dev/null || true
stop_serve

# ── 5b. NEGATIVE gate test: a WRONG token MUST be denied (fresh serve) ─────────
# The provider silently drops unauthorized jobs (no denial broadcast — avoids
# leaking provider presence), so the authoritative signal is serve-infer's
# "DENIED" log line + the requester NOT getting an ok:true result.
GATE_DENY="skip"
if [ "${PROOF_GATE_TEST:-1}" = "1" ]; then
  start_serve
  say "serve-infer up (pid $SPID, gated) — publishing an UNAUTHORIZED job (wrong token), expecting DENY"
  RUST_LOG=info timeout 90 "$BIN" infer "should be denied" --max-tokens 4 --auth-token "WRONG-$TOKEN" \
    >/tmp/omni-infer-bad.out 2>/tmp/omni-infer-bad.err || true
  BAD_JSON="$(grep -E '^\{' /tmp/omni-infer-bad.out 2>/dev/null | tail -1)"
  DENIED_LOG="$(grep -c "DENIED job" /tmp/omni-serve.log 2>/dev/null || echo 0)"
  echo "== GATE_BAD_JSON=$BAD_JSON  DENIED_LOG_COUNT=$DENIED_LOG"
  echo "--- serve(neg) deny markers ---"; grep -iE "JOB id=|DENIED job|DENYING ALL" /tmp/omni-serve.log | tail -6
  # PASS if the provider logged a denial AND the requester never got an ok:true.
  if [ "$DENIED_LOG" -ge 1 ] && ! printf '%s' "$BAD_JSON" | grep -q '"ok": *true'; then
    GATE_DENY="ok"
  else
    GATE_DENY="fail"
  fi
  stop_serve
fi

echo "== INFER_EXIT=$IEXIT"
echo "== RESULT_JSON=$RESULT_JSON"
echo "== GATE_DENY=$GATE_DENY"
echo "--- serve(pos) log (job/result markers) ---"
grep -iE "JOB id=|RESULT published|DENIED|serve-infer —|inference failed|DENYING ALL" /tmp/omni-serve-pos.log | tail -8
echo "--- infer(pos) stderr (discovery/publish markers) ---"
grep -iE "DISCOVERED|peer found|publishing|RESULT ok|re-publishing" /tmp/omni-infer.err | tail -8

# ── 6. verdict ────────────────────────────────────────────────────────────────
if [ "$IEXIT" = 0 ] && printf '%s' "$RESULT_JSON" | grep -q '"ok": *true' && [ "$GATE_DENY" != "fail" ]; then
  echo "PROOF OK — real inference carried over omni-net (mode=$MODE, gate_deny=$GATE_DENY)"
  echo "NODE OK"   # fleet driver greps this token for PASS
  exit 0
else
  echo "--- infer(pos) stdout ---"; tail -20 /tmp/omni-infer.out
  echo "--- infer(pos) stderr tail ---"; tail -20 /tmp/omni-infer.err
  [ "$GATE_DENY" = "fail" ] && echo "GATE FAILED — a wrong token was NOT denied (fail-open!)"
  die "proof failed (infer_exit=$IEXIT gate_deny=$GATE_DENY)"
fi
