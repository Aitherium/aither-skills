#!/usr/bin/env bash
# flux-node-up.sh — bootstrap a Flux event-plane listener on this node.
#
# Brings a node to a running Flux listener container that participates in
# the AitherMesh event-plane. Runs idempotently: if the container already
# exists, it is stopped and replaced.
#
# Environment variables (defaults shown):
#   FLUX_IMAGE         Docker image to run (default: aitheros-mesh-agent:dgx-arm64)
#   FLUX_PORT          Port to bind flux listener (default: 8117)
#   MESH_SRC           Host path to mount as /app (default: /opt/aitheros/mesh-src)
#   NODE_ID            Mesh node identifier (required; e.g., spark-dgx)
#   AITHER_INTERNAL_SECRET  Service-internal secret from vault (required; never echoed)
#
# Usage:
#   ./flux-node-up.sh             # Start flux with defaults
#   NODE_ID=my-node ./flux-node-up.sh  # Override NODE_ID
#
# The script will:
#   1. Validate required inputs
#   2. Stop any existing 'aither-flux' container
#   3. Run a fresh container with proper environment and mounts
#   4. Poll for /health endpoint to confirm readiness
#   5. Exit 0 on success, 1 on failure
#
set -euo pipefail

FLUX_IMAGE="${FLUX_IMAGE:-aitheros-mesh-agent:dgx-arm64}"
FLUX_PORT="${FLUX_PORT:-8117}"
MESH_SRC="${MESH_SRC:-/opt/aitheros/mesh-src}"
NODE_ID="${NODE_ID:-}"
AITHER_INTERNAL_SECRET="${AITHER_INTERNAL_SECRET:-}"
CONTAINER_NAME="aither-flux"

say() { printf '\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ── Validation ───────────────────────────────────────────────────────────
say "validating flux configuration"

if [ -z "$NODE_ID" ]; then
  die "NODE_ID is required (set as environment variable or pass via adk mesh flux-node)"
fi

if [ -z "$AITHER_INTERNAL_SECRET" ]; then
  die "AITHER_INTERNAL_SECRET is required (fetch from vault: adk secret get AITHER_INTERNAL_SECRET)"
fi

echo "   flux_image=$FLUX_IMAGE"
echo "   flux_port=$FLUX_PORT"
echo "   mesh_src=$MESH_SRC"
echo "   node_id=$NODE_ID"
echo "   container=$CONTAINER_NAME"

# ── Stop existing container (idempotent) ─────────────────────────────────
say "stopping any existing flux container"
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# ── Run flux listener ────────────────────────────────────────────────────
say "starting flux listener container"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "$FLUX_PORT:$FLUX_PORT" \
  -v "$MESH_SRC:/app" \
  -w /app \
  -e "AITHER_SERVICE=flux" \
  -e "AITHERFLUX_PORT=$FLUX_PORT" \
  -e "AITHER_NODE_ID=$NODE_ID" \
  -e "AITHER_INTERNAL_SECRET=$AITHER_INTERNAL_SECRET" \
  --health-cmd="curl -sf localhost:$FLUX_PORT/health || exit 1" \
  --health-interval=5s \
  --health-timeout=3s \
  --health-retries=3 \
  --health-start-period=10s \
  "$FLUX_IMAGE" \
  sh -c "exec python -m uvicorn services.security.AitherFlux:app --host 0.0.0.0 --port $FLUX_PORT" \
  || die "docker run failed — check docker daemon and image availability"

echo "   container started (id: $(docker ps -aq -f name=$CONTAINER_NAME | cut -c1-12))"

# ── Wait for health ──────────────────────────────────────────────────────
say "waiting for flux listener to be ready"
for attempt in $(seq 1 30); do
  if curl -sf "http://localhost:$FLUX_PORT/health" >/dev/null 2>&1; then
    printf '\033[32m== FLUX OK — listener ready on port %s\033[0m\n' "$FLUX_PORT"
    echo "   container: docker exec $CONTAINER_NAME bash"
    echo "   logs:      docker logs -f $CONTAINER_NAME"
    exit 0
  fi
  echo "   (attempt $attempt: waiting for readiness…)"
  sleep 1
done

die "flux listener did not become healthy (30s timeout) — " \
    "check logs: docker logs $CONTAINER_NAME"
