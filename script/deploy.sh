#!/usr/bin/env bash
# one deploy wrapper for every environment. it sources a values-only file
# (script/env/<env>.env) and runs the same build, preflight, deploy, resume and
# postflight path for local and mainnet. environments are data, the code path is
# one. secrets never enter here: local impersonates the factory owner on the fork
# (anvil --auto-impersonate), mainnet signs from the owner's own wallet and reads
# the rpc from the shell or a gitignored overlay.
#
#   script/deploy.sh local            deploy to the local anvil fork
#   DRY_RUN=1 script/deploy.sh local  simulate, no broadcast, no state change
#   script/deploy.sh mainnet          refuses until script/env/mainnet.env is filled
#
# the mainnet rpc is never stored in a file: it comes from MAINNET_RPC_URL in the
# shell or from the gitignored overlay script/env/mainnet.local.env. only the rpc
# host is printed, never the full url.
#
# on success it writes deployments/<chainId>.json in the shape the UI reads
# (web/CONNECTIONS.md). mainnet is NOT run end to end by this agent; the runbook
# is docs/DEPLOY.md.
set -euo pipefail

ENV="${1:-}"
[ -n "$ENV" ] || { echo "usage: script/deploy.sh <local|mainnet>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ENV_FILE="script/env/$ENV.env"
[ -f "$ENV_FILE" ] || { echo "no env file: $ENV_FILE" >&2; exit 2; }

fail() { echo "deploy.sh: $*" >&2; exit 1; }
warn() { echo "deploy.sh: WARN: $*" >&2; }

# an rpc passed in the shell wins over the env file default (the local e2e points this at its own anvil port)
RPC_URL_OVERRIDE="${RPC_URL:-}"
# values-only. no secrets in these files
set -a; . "$ENV_FILE"; set +a
# optional gitignored overlay for secrets-free overrides (the mainnet rpc lives here or in the shell)
OVERLAY="script/env/$ENV.local.env"
[ -f "$OVERLAY" ] && { set -a; . "$OVERLAY"; set +a; }
[ -n "$RPC_URL_OVERRIDE" ] && RPC_URL="$RPC_URL_OVERRIDE"
DRY_RUN="${DRY_RUN:-0}"

# the mainnet rpc never ships in a file: take the overlay value if it set one, else the shell MAINNET_RPC_URL
if [ "$ENV" = "mainnet" ] && [ -z "${RPC_URL:-}" ]; then
  RPC_URL="${MAINNET_RPC_URL:?set MAINNET_RPC_URL in the shell or RPC_URL in $OVERLAY for mainnet}"
fi

# ------------------------------------------------------------------ guards

[ -n "${CHAIN_ID:-}" ] || fail "CHAIN_ID unset in $ENV_FILE"
[ -n "${LAUNCH_CONFIG:-}" ] || fail "LAUNCH_CONFIG unset in $ENV_FILE"
[ -f "$LAUNCH_CONFIG" ] || fail "LAUNCH_CONFIG file missing: $LAUNCH_CONFIG"

# required values that ship empty in mainnet.env so the wrapper refuses
for k in RPC_URL DEPLOYER WALLET_MODE; do
  v="${!k:-}"
  [ -n "$v" ] || fail "$k is empty: fill it before deploying $ENV"
done

# git guards: a fail unless DRY_RUN, where they warn
if [ "${MAIN_BRANCH_GUARD:-0}" = "1" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  dirty="$(git status --porcelain)"
  msg_branch="not on main (on $branch)"
  msg_dirty="the tree is dirty"
  if [ "$branch" != "main" ]; then [ "$DRY_RUN" = "1" ] && warn "$msg_branch" || fail "$msg_branch"; fi
  if [ -n "$dirty" ]; then [ "$DRY_RUN" = "1" ] && warn "$msg_dirty" || fail "$msg_dirty"; fi
fi

# the rpc host, the only part of the url that is ever printed
host="$(printf '%s' "$RPC_URL" | sed -E 's#^[a-z]+://([^/@:]*@)?([^/:]+).*#\2#')"

# local never broadcasts anywhere but a local node, in dry run too
if [ "$ENV" = "local" ]; then
  case "$host" in
    127.0.0.1|localhost) ;;
    *) fail "env local refuses a non-local rpc host: $host" ;;
  esac
fi

# the rpc chain id must be the env's chain id, so the mainnet env only ever reaches chain 1 and local only 31337
ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")" || fail "could not read the chain id from the rpc host $host"
[ "$ACTUAL_CHAIN_ID" = "$CHAIN_ID" ] || fail "rpc chain id $ACTUAL_CHAIN_ID is not CHAIN_ID $CHAIN_ID for env $ENV"
# the preflight and deploy scripts read this and fail their chain id row on any other chain
export EXPECTED_CHAIN_ID="$CHAIN_ID"

# ------------------------------------------------------------------ wallet flags, built and validated once

case "$WALLET_MODE" in
  unlocked)
    [ "$ENV" = "local" ] || fail "WALLET_MODE unlocked is allowed only for env local"
    BROADCAST_FLAGS="--unlocked --sender $DEPLOYER" ;;
  account)
    [ -n "${WALLET_ACCOUNT:-}" ] || fail "WALLET_MODE account needs WALLET_ACCOUNT set"
    BROADCAST_FLAGS="--account $WALLET_ACCOUNT --sender $DEPLOYER" ;;
  ledger)
    BROADCAST_FLAGS="--ledger --sender $DEPLOYER" ;;
  *)
    fail "unknown WALLET_MODE: $WALLET_MODE (unlocked, account or ledger)" ;;
esac

echo "deploy.sh: env=$ENV chainId=$CHAIN_ID rpcHost=$host config=$LAUNCH_CONFIG dryRun=$DRY_RUN"

# ------------------------------------------------------------------ build first (warm, then act)

FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-default}" forge build >/dev/null
echo "deploy.sh: build ok"

FACTORY="$(jq -r .stack.factory "$LAUNCH_CONFIG")"
HOOK="$(jq -r .stack.hook "$LAUNCH_CONFIG")"
POOL_FEE="$(jq -r .stack.poolFee "$LAUNCH_CONFIG")"
TICK_SPACING="$(jq -r .stack.tickSpacing "$LAUNCH_CONFIG")"

# ------------------------------------------------------------------ local: fund and open the factory as the impersonated owner

SNAP=""
PREV_SKIM=""
if [ "$ENV" = "local" ]; then
  # the current factory floor, restored after the launch (or reverted in dry run). read before any change
  PREV_SKIM="$(cast call "$FACTORY" "minProtocolSkimShareBps()(uint16)" --rpc-url "$RPC_URL")"
  # a dry run must leave the node untouched: snapshot before the cheats and revert after the simulation
  [ "$DRY_RUN" = "1" ] && SNAP="$(cast rpc evm_snapshot --rpc-url "$RPC_URL" | tr -d '"')"
  # fund the deployer (the real v2 factory owner, impersonated) for the fee and the gas
  cast rpc anvil_setBalance "$DEPLOYER" 0x21e19e0c9bab2400000 --rpc-url "$RPC_URL" >/dev/null
  # the one owner command the launch needs (docs/DEPLOY.md step 3): the factory owner lowers the minimum protocol skim
  # share so the bounty fits. the owner is the factory owner, impersonated
  BOUNTY="$(jq -r .launch.bountyBps "$LAUNCH_CONFIG")"
  SHARE=$((10000 - BOUNTY))
  cast send "$FACTORY" "setMinProtocolSkimShareBps(uint16)" "$SHARE" --from "$DEPLOYER" --unlocked --rpc-url "$RPC_URL" >/dev/null
  echo "deploy.sh: setMinProtocolSkimShareBps($SHARE) as the impersonated factory owner"
fi

# reverts the local dry run cheats (balance, skim, the block and the nonce the cast send took)
revert_dry_run() {
  [ -n "$SNAP" ] && cast rpc evm_revert "$SNAP" --rpc-url "$RPC_URL" >/dev/null && echo "deploy.sh: reverted the dry run state"
}

# ------------------------------------------------------------------ preflight (read only), captures the sign off values

echo "deploy.sh: preflight"
PRE="$(DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Preflight.s.sol --rpc-url "$RPC_URL" --sender "$DEPLOYER" 2>&1)" || { echo "$PRE" | tail -40; revert_dry_run; fail "preflight reverted"; }
CONFIG_HASH="$(printf '%s\n' "$PRE" | grep -oE 'CONFIG_HASH=0x[0-9a-fA-F]+' | tail -1 | cut -d= -f2)"
CONTROLLER_NONCE="$(printf '%s\n' "$PRE" | grep -oE 'CONTROLLER_NONCE=[0-9]+' | tail -1 | cut -d= -f2)"
[ -n "$CONFIG_HASH" ] || { echo "$PRE" | tail -40; revert_dry_run; fail "no CONFIG_HASH from preflight"; }
[ -n "$CONTROLLER_NONCE" ] || { revert_dry_run; fail "no CONTROLLER_NONCE from preflight"; }
echo "deploy.sh: CONFIG_HASH=$CONFIG_HASH CONTROLLER_NONCE=$CONTROLLER_NONCE"

# ------------------------------------------------------------------ deploy

if [ "$DRY_RUN" = "1" ]; then
  echo "deploy.sh: DRY_RUN deploy simulation (no broadcast, no wallet)"
  CONFIG_HASH="$CONFIG_HASH" CONTROLLER_NONCE="$CONTROLLER_NONCE" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
    forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender "$DEPLOYER" || { revert_dry_run; fail "dry run simulation reverted"; }
  revert_dry_run
  echo "deploy.sh: dry run complete, nothing sent"
  exit 0
fi

echo "deploy.sh: deploy (broadcast)"
# shellcheck disable=SC2086
DEP="$(CONFIG_HASH="$CONFIG_HASH" CONTROLLER_NONCE="$CONTROLLER_NONCE" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --slow $BROADCAST_FLAGS 2>&1)" \
  || { echo "$DEP" | tail -60; fail "deploy reverted"; }
printf '%s\n' "$DEP" | grep -E '^[[:space:]]+(core|coin|controller|router|lens|gas of step)' || true

pick() { printf '%s\n' "$DEP" | grep -oE "^[[:space:]]+$1 0x[0-9a-fA-F]{40}" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
CORE="$(pick core)"; COIN="$(pick coin)"; CONTROLLER="$(pick controller)"; ROUTER="$(pick router)"; LENS="$(pick lens)"
[ -n "$CORE" ] && [ -n "$COIN" ] && [ -n "$CONTROLLER" ] && [ -n "$ROUTER" ] && [ -n "$LENS" ] \
  || { echo "$DEP" | tail -60; fail "could not read deployed addresses"; }

# ------------------------------------------------------------------ resume: the split start (launch time plus the window)

echo "deploy.sh: resume (split start)"
# shellcheck disable=SC2086
CORE="$CORE" DEPLOYER="$DEPLOYER" CONFIG_HASH="$CONFIG_HASH" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Resume.s.sol --rpc-url "$RPC_URL" --broadcast --slow $BROADCAST_FLAGS >/dev/null \
  || fail "resume reverted"

# local: restore the factory floor to the value it held before the launch, the way the runbook does after the launch
if [ "$ENV" = "local" ]; then
  cast send "$FACTORY" "setMinProtocolSkimShareBps(uint16)" "$PREV_SKIM" --from "$DEPLOYER" --unlocked --rpc-url "$RPC_URL" >/dev/null
fi

# ------------------------------------------------------------------ postflight (read only)

echo "deploy.sh: postflight"
CORE="$CORE" DEPLOYER="$DEPLOYER" CONFIG_HASH="$CONFIG_HASH" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Postflight.s.sol --rpc-url "$RPC_URL" >/dev/null \
  || fail "postflight reverted"
echo "deploy.sh: postflight ok"

# ------------------------------------------------------------------ deployment record (the shape the UI reads)

mkdir -p deployments
BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
ENC="$(cast abi-encode 'f((address,address,uint24,int24,address))' "(0x0000000000000000000000000000000000000000,$COIN,$POOL_FEE,$TICK_SPACING,$HOOK)")"
POOL_ID="$(cast keccak "$ENC")"
CREDITS=0x97630aA70AB14ed9883B41dAfccBc11349723043
STATEMENTS=0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b
CREDIT_SCORE=0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7
REC="deployments/$CHAIN_ID.json"
cat > "$REC" <<JSON
{
  "chainId": $CHAIN_ID,
  "block": $BLOCK,
  "core": "$CORE",
  "coin": "$COIN",
  "controller": "$CONTROLLER",
  "router": "$ROUTER",
  "lens": "$LENS",
  "poolId": "$POOL_ID",
  "hook": "$HOOK",
  "credits": "$CREDITS",
  "statements": "$STATEMENTS",
  "creditScore": "$CREDIT_SCORE",
  "exitToken": null,
  "exitModule": null
}
JSON
echo "deploy.sh: wrote $REC"
cat "$REC"
