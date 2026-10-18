#!/usr/bin/env bash
# Read-only acceptance of the deployed chain-1 indexer after its historical backfill has completed.
# Usage: RPC_URL=<read rpc> indexer/check-live.sh mainnet
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$#" == 1 && "$1" == mainnet ]] || { echo "usage: RPC_URL=<read rpc> indexer/check-live.sh mainnet" >&2; exit 2; }
source indexer/env/mainnet.env
RPC_URL="$(printenv RPC_URL || true)"
[[ -n "$RPC_URL" ]] || { echo "RPC_URL is required for read-only Core checks" >&2; exit 1; }
RECORD=deployments/1.json
[[ -f "$RECORD" ]] || { echo "missing deferred mainnet record $RECORD" >&2; exit 1; }
CORE="$(jq -r .core "$RECORD")"
COIN="$(jq -r .coin "$RECORD")"
DEPLOY_BLOCK="$(jq -r .deployBlock "$RECORD")"
[[ "$(jq -r '.coinLive' "$RECORD")" == false ]] ||
  { echo "prelaunch acceptance requires coinLive=false" >&2; exit 1; }
[[ "$(cast chain-id --rpc-url "$RPC_URL")" == 1 ]] || { echo "RPC_URL is not Ethereum chain 1" >&2; exit 1; }
CORE_COIN="$(cast call "$CORE" 'COIN()(address)' --rpc-url "$RPC_URL" | awk '{print $1}')"
[[ "$(echo "$CORE_COIN" | tr 'A-F' 'a-f')" == "$(echo "$COIN" | tr 'A-F' 'a-f')" ]] ||
  { echo "record coin does not match Core.COIN" >&2; exit 1; }
[[ "$(cast code "$COIN" --rpc-url "$RPC_URL")" == 0x ]] ||
  { echo "deferred record says coinless but coin has code" >&2; exit 1; }
HEAD="$(cast block-number --rpc-url "$RPC_URL")"
PILE="$(cast call "$CORE" 'pileSize()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
POT="$(cast call "$CORE" 'ethPot()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')"
URL="$(printenv INDEXER_URL || true)"
if [[ -z "$URL" ]]; then
  APP="$(awk -F'"' '/^app[[:space:]]*=/ {print $2; exit}' "indexer/$FLY_CONFIG")"
  [[ -n "$APP" ]] || { echo "no app in indexer/$FLY_CONFIG" >&2; exit 1; }
  URL="https://$APP.fly.dev"
fi
URL="$(printf '%s' "$URL" | sed 's:/*$::')"
curl -fsS --max-time 10 "$URL/ready" >/dev/null
curl -fsS --max-time 10 "$URL/health/parity" >/dev/null
(cd indexer && node scripts/check-service.mjs "$URL" 1 "$CORE" "$COIN" "$DEPLOY_BLOCK" \
  "$PILE" "$POT" "$HEAD" 5 1)
echo "indexer production read-only acceptance passed at chain block $HEAD"
