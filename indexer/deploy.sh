#!/usr/bin/env bash
# One deploy path for the indexer (docs/INDEXER.md section 10). The environment is data: indexer/env/<env>.env
# holds values only, deployments/<chainId>.json holds addresses and the Core deploy block.
#
# Usage: indexer/deploy.sh <local|mainnet>
#
#   1. Reads env/<env>.env and deployments/<CHAIN_ID>.json. Refuses on a missing record, an empty required
#      value, or a DATABASE_SCHEMA already used for a different Core address (indexer/deployments.json).
#   2. TARGET=fly: `fly deploy` with the record values as release env. TARGET=local: starts `ponder start`
#      in the foreground against the record's rpcUrl with PGlite.
#   3. TARGET=fly, after deploy: binds the schema to the Core, then requires healthy HTTP probes.
#
# DRY_RUN=1 evaluates every check and prints the command without running it (needs no fly CLI, wallet or network).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_NAME="${1:-}"
ENV_FILE="indexer/env/${ENV_NAME}.env"
[[ -n "$ENV_NAME" && -f "$ENV_FILE" ]] || { echo "usage: indexer/deploy.sh <local|mainnet>" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

need() { [[ -n "${!1:-}" ]] || { echo "refusing: $1 is empty in $ENV_FILE" >&2; exit 1; }; }
for k in CHAIN_ID TARGET DATABASE_SCHEMA; do need "$k"; done

RECORD="deployments/${CHAIN_ID}.json"
[[ -f "$RECORD" ]] || { echo "refusing: $RECORD does not exist; deploy the contracts first (script/deploy.sh)" >&2; exit 1; }
rec() { jq -r --arg k "$1" '.[$k] // empty' "$RECORD"; }
CORE=$(rec core); COIN=$(rec coin); CREDITS=$(rec credits); STATEMENTS=$(rec statements); DEPLOY_BLOCK=$(rec deployBlock)
for k in CORE COIN CREDITS STATEMENTS DEPLOY_BLOCK; do [[ -n "${!k}" ]] || { echo "refusing: $RECORD has no value for $k" >&2; exit 1; }; done
if [[ "$CHAIN_ID" == "1" ]]; then need CREDITS_START_BLOCK; need STATEMENTS_START_BLOCK; need STRATEGY_START_BLOCK; fi

LEDGER="indexer/deployments.json"
PRIOR=""
[[ -f "$LEDGER" ]] && PRIOR=$(jq -r --arg s "$DATABASE_SCHEMA" '.[$s] // empty' "$LEDGER")
CORE_LC=$(echo "$CORE" | tr 'A-F' 'a-f')
if [[ -n "$PRIOR" && "$PRIOR" != "$CORE_LC" ]]; then
  echo "refusing: schema '$DATABASE_SCHEMA' was used for $PRIOR, not $CORE_LC; bump DATABASE_SCHEMA in $ENV_FILE" >&2
  exit 1
fi

echo "env:       $ENV_NAME ($TARGET)"
echo "chain id:  $CHAIN_ID"
echo "schema:    $DATABASE_SCHEMA"
echo "core:      $CORE"
echo "from:      $DEPLOY_BLOCK"
echo "credits:   $CREDITS (start ${CREDITS_START_BLOCK:-core deploy block})"
echo "statements:$STATEMENTS (start ${STATEMENTS_START_BLOCK:-core deploy block})"
echo "strategy:  start ${STRATEGY_START_BLOCK:-local default}"

# Release values passed to the app; the key names are the ones ponder.config.ts reads.
VARS=(CHAIN_ID=$CHAIN_ID CORE_ADDRESS=$CORE COIN_ADDRESS=$COIN CREDITS_ADDRESS=$CREDITS STATEMENTS_ADDRESS=$STATEMENTS
  DEPLOY_BLOCK=$DEPLOY_BLOCK DATABASE_SCHEMA=$DATABASE_SCHEMA)
for k in VIEWS_SCHEMA CREDITS_START_BLOCK STATEMENTS_START_BLOCK STRATEGY_START_BLOCK RPC_RPS PONDER_POLL_INTERVAL_MS PONDER_ETH_GETLOGS_BLOCK_RANGE SNAPSHOT_INTERVAL_BLOCKS; do
  [[ -n "${!k:-}" ]] && VARS+=("$k=${!k}")
done

case "$TARGET" in
  fly)
    need FLY_CONFIG
    APP=$(awk -F'"' '/^app[[:space:]]*=/ {print $2; exit}' "indexer/$FLY_CONFIG")
    [[ -n "$APP" ]] || { echo "refusing: no app in indexer/$FLY_CONFIG" >&2; exit 1; }
    CMD=(fly deploy --config "$FLY_CONFIG" -a "$APP")
    for v in "${VARS[@]}"; do CMD+=(-e "$v"); done
    ;;
  local)
    RPC_URL=$(rec rpcUrl); [[ -n "$RPC_URL" ]] || { echo "refusing: $RECORD has no rpcUrl" >&2; exit 1; }
    CMD=(env "${VARS[@]}" "RPC_URL=$RPC_URL" "DEPLOYMENT_RECORD=../$RECORD" ./node_modules/.bin/ponder start --schema "$DATABASE_SCHEMA" --port "${PORT:-42069}")
    ;;
  *) echo "refusing: TARGET must be fly or local" >&2; exit 1 ;;
esac

if [[ "${DRY_RUN:-}" == "1" ]]; then
  [[ "$TARGET" == "fly" ]] && command -v fly >/dev/null && fly config validate --config "indexer/$FLY_CONFIG"
  echo "DRY_RUN: would run (in indexer/):"; printf '  %q' "${CMD[@]}"; echo
  exit 0
fi

if [[ "$TARGET" == "local" ]]; then cd indexer && exec "${CMD[@]}"; fi

(cd indexer && "${CMD[@]}")
[[ -f "$LEDGER" ]] || echo '{}' > "$LEDGER"
# The deploy has already happened, so bind its schema even if catch-up or parity fails. A retry for a different
# Core must not reuse a database that may contain the first Core's rows.
jq --arg s "$DATABASE_SCHEMA" --arg a "$CORE_LC" '.[$s] = $a' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
URL="https://${APP}.fly.dev"
probe() {
  local path="$1" code
  if [[ "$path" == "/graphql" ]]; then
    code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST "$URL$path" \
      -H 'content-type: application/json' --data '{"query":"{ __typename }"}')" || code=000
  else
    code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$URL$path")" || code=000
  fi
  echo "$path: $code"
  [[ "$code" == "200" ]]
}
ATTEMPTS="$(printenv PROBE_ATTEMPTS || echo 30)"
INTERVAL="$(printenv PROBE_INTERVAL || echo 10)"
for attempt in $(seq 1 "$ATTEMPTS"); do
  failed=0
  for path in /health /ready /health/parity /graphql; do probe "$path" || failed=1; done
  [[ "$failed" == 0 ]] && exit 0
  if [[ "$attempt" -lt "$ATTEMPTS" ]]; then sleep "$INTERVAL"; fi
done
echo "indexer deployed to $APP but readiness or parity is unhealthy; schema $DATABASE_SCHEMA remains bound to $CORE" >&2
exit 1
