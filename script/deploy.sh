#!/usr/bin/env bash
# one deploy wrapper for every environment. it sources a values-only file
# (script/env/<env>.env) and runs the same build, preflight, deploy, resume and
# postflight path for local and mainnet. environments are data, the code path is
# one. secrets never enter here: local impersonates the factory owner on the fork
# (anvil --auto-impersonate), mainnet signs from the owner's own wallet.
#
#   script/deploy.sh local            deploy to the local anvil fork
#   DRY_RUN=1 script/deploy.sh local  simulate, no broadcast
#   script/deploy.sh mainnet          refuses until script/env/mainnet.env is filled
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

# values-only. no secrets in these files
set -a; . "$ENV_FILE"; set +a
DRY_RUN="${DRY_RUN:-0}"

fail() { echo "deploy.sh: $*" >&2; exit 1; }
warn() { echo "deploy.sh: WARN: $*" >&2; }

# ------------------------------------------------------------------ guards

[ -n "${CHAIN_ID:-}" ] || fail "CHAIN_ID unset in $ENV_FILE"
[ -n "${LAUNCH_CONFIG:-}" ] || fail "LAUNCH_CONFIG unset in $ENV_FILE"
[ -f "$LAUNCH_CONFIG" ] || fail "LAUNCH_CONFIG file missing: $LAUNCH_CONFIG"

# required values that ship empty in mainnet.env so the wrapper refuses
for k in RPC_URL DEPLOYER WALLET_MODE; do
  v="${!k:-}"
  [ -n "$v" ] || fail "$k is empty in $ENV_FILE: fill it before deploying $ENV"
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

# local never broadcasts anywhere but a local node
host="$(printf '%s' "$RPC_URL" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
if [ "$ENV" = "local" ] && [ "$DRY_RUN" != "1" ]; then
  case "$host" in
    127.0.0.1|localhost) ;;
    *) fail "env local refuses to broadcast to a non-local rpc host: $host" ;;
  esac
fi

echo "deploy.sh: env=$ENV chainId=$CHAIN_ID rpc=$RPC_URL config=$LAUNCH_CONFIG dryRun=$DRY_RUN"

# ------------------------------------------------------------------ build first (warm, then act)

FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-default}" forge build >/dev/null
echo "deploy.sh: build ok"

FACTORY="$(jq -r .stack.factory "$LAUNCH_CONFIG")"
HOOK="$(jq -r .stack.hook "$LAUNCH_CONFIG")"
POOL_FEE="$(jq -r .stack.poolFee "$LAUNCH_CONFIG")"
TICK_SPACING="$(jq -r .stack.tickSpacing "$LAUNCH_CONFIG")"

# ------------------------------------------------------------------ local: fund and open the factory as the impersonated owner

if [ "$ENV" = "local" ]; then
  # fund the deployer (the real v2 factory owner, impersonated) for the fee and the gas
  cast rpc anvil_setBalance "$DEPLOYER" 0x21e19e0c9bab2400000 --rpc-url "$RPC_URL" >/dev/null
  # the one owner command the launch needs (docs/DEPLOY.md step 3): the factory owner lowers the minimum protocol skim
  # share so the bounty fits. the owner is the factory owner, impersonated
  BOUNTY="$(jq -r .launch.bountyBps "$LAUNCH_CONFIG")"
  SHARE=$((10000 - BOUNTY))
  cast send "$FACTORY" "setMinProtocolSkimShareBps(uint16)" "$SHARE" --from "$DEPLOYER" --unlocked --rpc-url "$RPC_URL" >/dev/null
  echo "deploy.sh: setMinProtocolSkimShareBps($SHARE) as the impersonated factory owner"
fi

# ------------------------------------------------------------------ wallet flags per environment

broadcast_flags() {
  if [ "$WALLET_MODE" = "unlocked" ]; then
    echo "--unlocked --sender $DEPLOYER"
  elif [ "$WALLET_MODE" = "account" ]; then
    echo "--account ${WALLET_ACCOUNT:?WALLET_ACCOUNT unset} --sender $DEPLOYER"
  elif [ "$WALLET_MODE" = "ledger" ]; then
    echo "--ledger --sender $DEPLOYER"
  else
    fail "unknown WALLET_MODE: $WALLET_MODE"
  fi
}

# ------------------------------------------------------------------ preflight (read only), captures the sign off values

echo "deploy.sh: preflight"
PRE="$(DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Preflight.s.sol --rpc-url "$RPC_URL" --sender "$DEPLOYER" 2>&1)" || { echo "$PRE" | tail -40; fail "preflight reverted"; }
CONFIG_HASH="$(printf '%s\n' "$PRE" | grep -oE 'CONFIG_HASH=0x[0-9a-fA-F]+' | tail -1 | cut -d= -f2)"
CONTROLLER_NONCE="$(printf '%s\n' "$PRE" | grep -oE 'CONTROLLER_NONCE=[0-9]+' | tail -1 | cut -d= -f2)"
[ -n "$CONFIG_HASH" ] || { echo "$PRE" | tail -40; fail "no CONFIG_HASH from preflight"; }
[ -n "$CONTROLLER_NONCE" ] || fail "no CONTROLLER_NONCE from preflight"
echo "deploy.sh: CONFIG_HASH=$CONFIG_HASH CONTROLLER_NONCE=$CONTROLLER_NONCE"

# ------------------------------------------------------------------ deploy

if [ "$DRY_RUN" = "1" ]; then
  echo "deploy.sh: DRY_RUN deploy simulation (no broadcast, no wallet)"
  CONFIG_HASH="$CONFIG_HASH" CONTROLLER_NONCE="$CONTROLLER_NONCE" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
    forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender "$DEPLOYER"
  echo "deploy.sh: dry run complete, nothing sent"
  exit 0
fi

echo "deploy.sh: deploy (broadcast)"
# shellcheck disable=SC2046
DEP="$(CONFIG_HASH="$CONFIG_HASH" CONTROLLER_NONCE="$CONTROLLER_NONCE" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --slow $(broadcast_flags) 2>&1)" \
  || { echo "$DEP" | tail -60; fail "deploy reverted"; }
printf '%s\n' "$DEP" | grep -E '^[[:space:]]+(core|coin|controller|router|lens|gas of step)' || true

pick() { printf '%s\n' "$DEP" | grep -oE "^[[:space:]]+$1 0x[0-9a-fA-F]{40}" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
CORE="$(pick core)"; COIN="$(pick coin)"; CONTROLLER="$(pick controller)"; ROUTER="$(pick router)"; LENS="$(pick lens)"
[ -n "$CORE" ] && [ -n "$COIN" ] && [ -n "$ROUTER" ] && [ -n "$LENS" ] || { echo "$DEP" | tail -60; fail "could not read deployed addresses"; }

# ------------------------------------------------------------------ resume: the split start (launch time plus the window)

echo "deploy.sh: resume (split start)"
# shellcheck disable=SC2046
CORE="$CORE" DEPLOYER="$DEPLOYER" CONFIG_HASH="$CONFIG_HASH" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Resume.s.sol --rpc-url "$RPC_URL" --broadcast --slow $(broadcast_flags) >/dev/null \
  || fail "resume reverted"

# local: restore the factory floor the way the runbook does after the launch (harmless locally, faithful to mainnet)
if [ "$ENV" = "local" ]; then
  cast send "$FACTORY" "setMinProtocolSkimShareBps(uint16)" 1000 --from "$DEPLOYER" --unlocked --rpc-url "$RPC_URL" >/dev/null
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
