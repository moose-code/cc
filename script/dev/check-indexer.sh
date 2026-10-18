#!/usr/bin/env bash
# promise: a seeded Anvil Core can be indexed through Ponder's production Postgres and SQL paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[[ -n "$DATABASE_URL" ]] || { echo "DATABASE_URL is empty" >&2; exit 1; }
PORT="$(printenv PORT || echo 8619)"
INDEXER_PORT="$(printenv INDEXER_PORT || echo 42169)"
RPC="http://127.0.0.1:$PORT"
ORIGIN="http://127.0.0.1:$INDEXER_PORT"
if lsof -ti "tcp:$INDEXER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "indexer port $INDEXER_PORT is already in use" >&2
  exit 1
fi
RECORD="deployments/31337.json"
[[ -f "$RECORD" ]] || { echo "missing $RECORD" >&2; exit 1; }
[[ "$(cast chain-id --rpc-url "$RPC")" == "31337" ]] || { echo "expected local Anvil chain 31337" >&2; exit 1; }
CORE="$(jq -r .core "$RECORD")"
COIN="$(jq -r .coin "$RECORD")"
START="$(jq -r .deployBlock "$RECORD")"

# A Tick after the last seeded action creates a parity row and a fresh engine snapshot.
cast rpc anvil_mine 0x12d --rpc-url "$RPC" >/dev/null
TARGET="$(cast block-number --rpc-url "$RPC")"
PILE="$(cast call "$CORE" 'pileSize()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
POT="$(cast call "$CORE" 'ethPot()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"

LOG="$(mktemp)"
SMOKE_LOG="$(mktemp)"
(
  cd indexer
  # Ponder reads PORT from its environment, so do not pass it Anvil's port.
  exec env PORT="$INDEXER_PORT" CHAIN_ID=31337 DATABASE_URL="$DATABASE_URL" DATABASE_SCHEMA=cc_candidate \
    DEPLOYMENT_RECORD="../$RECORD" RPC_URL="$RPC" STRATEGY_START_BLOCK="$START" \
    PONDER_POLL_INTERVAL_MS=1000 ./node_modules/.bin/ponder start \
    --schema cc_candidate --hostname 127.0.0.1 --port "$INDEXER_PORT" >"$LOG" 2>&1
) &
PONDER_PID=$!
trap 'kill "$PONDER_PID" 2>/dev/null || true; wait "$PONDER_PID" 2>/dev/null || true; rm -f "$LOG" "$SMOKE_LOG"' EXIT

for _ in $(seq 1 180); do
  if ! kill -0 "$PONDER_PID" 2>/dev/null; then
    tail -80 "$LOG" >&2
    echo "Ponder stopped before readiness" >&2
    exit 1
  fi
  if curl -fsS --max-time 2 "$ORIGIN/ready" >/dev/null 2>&1 &&
     curl -fsS --max-time 2 "$ORIGIN/health/parity" >/dev/null 2>&1 &&
     (cd indexer && node scripts/check-service.mjs "$ORIGIN" 31337 "$CORE" "$COIN" "$START" \
       "$PILE" "$POT" "$TARGET" 0 1) >"$SMOKE_LOG" 2>&1; then
    cat "$SMOKE_LOG"
    echo "indexer candidate smoke passed at block $TARGET"
    exit 0
  fi
  sleep 2
done
echo "indexer smoke target block: $TARGET" >&2
for PATH_SUFFIX in ready health/parity; do
  echo "GET /$PATH_SUFFIX" >&2
  curl -sS --max-time 5 -w '\nHTTP %{http_code}\n' "$ORIGIN/$PATH_SUFFIX" >&2 || true
done
(cd indexer && node scripts/check-service.mjs "$ORIGIN" 31337 "$CORE" "$COIN" "$START" \
  "$PILE" "$POT" "$TARGET" 0 1) >&2 || true
tail -80 "$LOG" >&2
tail -40 "$SMOKE_LOG" >&2
echo "indexer did not reach a reconciled SQL projection" >&2
exit 1
