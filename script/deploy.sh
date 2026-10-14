#!/usr/bin/env bash
# the deploy path for the local anvil fork: fund the factory owner, lower the factory's minimum protocol skim share
# (docs/RUNBOOK.md step 3), run Preflight, Deploy and Postflight, restore the factory floor and write
# deployments/31337.json. values come from script/env/local.env; RPC_URL in the shell overrides it. the launch on
# mainnet follows docs/RUNBOOK.md.
#
#   script/deploy.sh local
#
# the scripts require chain id 1 (Checks.sol), so forge is run with --chain-id 1; the node itself stays chain 31337
# and the record carries 31337.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV="${1:-}"
[ "$ENV" = "local" ] || { echo "usage: script/deploy.sh local" >&2; exit 2; }
fail() { echo "deploy.sh: $*" >&2; exit 1; }

RPC_OVERRIDE="${RPC_URL:-}"
set -a; . "script/env/$ENV.env"; set +a
[ -n "$RPC_OVERRIDE" ] && RPC_URL="$RPC_OVERRIDE"

case "$(printf '%s' "$RPC_URL" | sed -E 's#^[a-z]+://([^/@:]*@)?([^/:]+).*#\2#')" in
  127.0.0.1|localhost) ;;
  *) fail "env local refuses a non local rpc: $RPC_URL" ;;
esac
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "$CHAIN_ID" ] || fail "the rpc is not chain $CHAIN_ID"

BUILD="$(forge build 2>&1)" || { echo "$BUILD" | tail -40; fail "build failed"; }
echo "deploy.sh: build ok, rpc $RPC_URL config $LAUNCH_CONFIG"

FACTORY="$(jq -r .stack.factory "$LAUNCH_CONFIG")"
HOOK="$(jq -r .stack.hook "$LAUNCH_CONFIG")"
FLAGS=(--rpc-url "$RPC_URL" --chain-id 1 --sender "$DEPLOYER")

START="$(cast block-number --rpc-url "$RPC_URL")"
PREV_SKIM="$(cast call "$FACTORY" "minProtocolSkimShareBps()(uint16)" --rpc-url "$RPC_URL")"
cast rpc anvil_setBalance "$DEPLOYER" 0x21e19e0c9bab2400000 --rpc-url "$RPC_URL" >/dev/null
SHARE=$((10000 - $(jq -r .launch.bountyBps "$LAUNCH_CONFIG")))
cast send "$FACTORY" "setMinProtocolSkimShareBps(uint16)" "$SHARE" --from "$DEPLOYER" --unlocked --rpc-url "$RPC_URL" >/dev/null
echo "deploy.sh: setMinProtocolSkimShareBps($SHARE) as the factory owner"

echo "deploy.sh: preflight"
PRE="$(DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" forge script script/Preflight.s.sol "${FLAGS[@]}" 2>&1)" \
  || { echo "$PRE" | tail -40; fail "preflight failed"; }
CONFIG_HASH="$(printf '%s\n' "$PRE" | grep -oE 'CONFIG_HASH=0x[0-9a-fA-F]+' | tail -1 | cut -d= -f2)"
[ -n "$CONFIG_HASH" ] || fail "no CONFIG_HASH from preflight"

echo "deploy.sh: deploy"
DEP="$(CONFIG_HASH="$CONFIG_HASH" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Deploy.s.sol "${FLAGS[@]}" --unlocked --broadcast --slow 2>&1)" \
  || { echo "$DEP" | tail -60; fail "deploy failed"; }
pick() { printf '%s\n' "$1" | grep -oE "^[[:space:]]*$2 0x[0-9a-fA-F]{40}" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
CORE="$(pick "$DEP" core)"; COIN="$(pick "$DEP" coin)"; CONTROLLER="$(pick "$DEP" controller)"
SEAPORT="$(pick "$DEP" 'seaport adapter')"; STRATEGY="$(pick "$DEP" 'strategy adapter')"; RENDERER="$(pick "$DEP" renderer)"
[ -n "$CORE" ] && [ -n "$COIN" ] && [ -n "$CONTROLLER" ] && [ -n "$SEAPORT" ] && [ -n "$STRATEGY" ] && [ -n "$RENDERER" ] \
  || { echo "$DEP" | tail -60; fail "could not read the deployed addresses"; }

cast send "$FACTORY" "setMinProtocolSkimShareBps(uint16)" "$PREV_SKIM" --from "$DEPLOYER" --unlocked --rpc-url "$RPC_URL" >/dev/null

echo "deploy.sh: postflight"
POST="$(CORE="$CORE" DEPLOYER="$DEPLOYER" CONFIG_HASH="$CONFIG_HASH" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Postflight.s.sol "${FLAGS[@]}" 2>&1)" || { echo "$POST" | tail -40; fail "postflight failed"; }
LIB="$(printf '%s\n' "$POST" | grep -oE 'verify: library CoreLib at 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')"
[ -n "$LIB" ] || fail "no library address from postflight"

# the block of the Core creation: the first block from the start of this run with code at the Core address
lo="$START"; hi="$(cast block-number --rpc-url "$RPC_URL")"
while [ "$lo" -lt "$hi" ]; do
  mid=$(((lo + hi) / 2))
  if [ "$(cast code "$CORE" --block "$mid" --rpc-url "$RPC_URL")" != 0x ]; then hi=$mid; else lo=$((mid + 1)); fi
done

mkdir -p deployments
jq -n --argjson chainId "$CHAIN_ID" --arg rpcUrl "$RPC_URL" --argjson deployBlock "$lo" \
  --arg core "$CORE" --arg controller "$CONTROLLER" --arg coin "$COIN" --arg seaport "$SEAPORT" \
  --arg strategy "$STRATEGY" --arg renderer "$RENDERER" --arg lib "$LIB" --arg hook "$HOOK" --arg owner "$DEPLOYER" \
  --argjson poolFee "$(jq .stack.poolFee "$LAUNCH_CONFIG")" --argjson tickSpacing "$(jq .stack.tickSpacing "$LAUNCH_CONFIG")" '{
  chainId: $chainId, rpcUrl: $rpcUrl, deployBlock: $deployBlock,
  core: $core, controller: $controller, coin: $coin, seaportAdapter: $seaport, strategyAdapter: $strategy, renderer: $renderer, library: $lib,
  credits: "0x97630aA70AB14ed9883B41dAfccBc11349723043", statements: "0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b",
  poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90", hook: $hook, poolFee: $poolFee, tickSpacing: $tickSpacing,
  balanceToken: null, balanceModule: null, balancePool: null, owner: $owner
}' > "deployments/$CHAIN_ID.json"
echo "deploy.sh: wrote deployments/$CHAIN_ID.json (core $CORE, deploy block $lo)"
