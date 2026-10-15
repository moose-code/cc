#!/usr/bin/env bash
# local end to end on an anvil mainnet fork: start anvil, deploy through script/deploy.sh, seed, run script/dev/Scenario.s.sol
# stage by stage with node time warps between them, and write the record deployments/<chainId>.json. a failed stage stops
# the run. every signer is an impersonated account (anvil --auto-impersonate, forge --unlocked).
#
#   PHASE=pre    the engine before the balance token: the module unset, balanceBidOn false, redeemOn as the config sets it (a redemption reverts NoBalanceModule).
#   PHASE=post   (default) Seed deploys the balance token, the best guess redeem module and an eth/balance pool and
#                switches the balance side on; the stages add a redemption and a balance bid.
#
#   script/dev/e2e.sh                  a fresh anvil on PORT (8545), run, stop anvil
#   KEEP=1 script/dev/e2e.sh           leave anvil running
#   STOP_AFTER=<stage> script/dev/e2e.sh   stop after that stage
#   NO_ANVIL=1 script/dev/e2e.sh       reuse the node at E2E_RPC_URL
#   FORK_URL=<archive rpc> script/dev/e2e.sh   the default is the Tenderly public gateway
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT="${PORT:-8545}"
E2E_RPC_URL="${E2E_RPC_URL:-http://127.0.0.1:$PORT}"
PHASE="${PHASE:-post}"
KEEP="${KEEP:-0}"
case "$PHASE" in pre|post) ;; *) echo "PHASE must be pre or post, got $PHASE" >&2; exit 2 ;; esac

# the node is chain id 31337 for both stacks; the dev wallet owns the factory and the engine. STACK=master is exported
# so script/deploy.sh and the forge scripts overlay the master stack record (the dev wallet is its fork owner too).
STACK="${STACK:-live}"
export STACK
OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
CHAIN="${CHAIN:-31337}"   # 1 on a chain id 1 node (script/dev/anvil.sh with CHAIN_ID=1)
export CHAIN_ID="$CHAIN"
A1=0x1111111111111111111111111111111111111111
A2=0x2222222222222222222222222222222222222222
A3=0x3333333333333333333333333333333333333333
KEEPER=0x4444444444444444444444444444444444444444
TRADER=0x5555555555555555555555555555555555555555
FUND=0x152d02c7e14af6800000   # 100000 ether
REC="deployments/$CHAIN.json"
CFG=script/config/anvil.json
DEV_WALLET="$(jq -r '.dev.wallet // empty' $CFG)"   # the owner's browser wallet, funded below and by the seed

say() { echo; echo "=== $* ==="; }
rpc() { cast rpc "$@" --rpc-url "$E2E_RPC_URL" >/dev/null; }
warp() { rpc evm_increaseTime "$1"; rpc evm_mine; }
call() { cast call "$@" --rpc-url "$E2E_RPC_URL"; }

ANVIL_PID=""
trap '[ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true' EXIT

if [ "${NO_ANVIL:-0}" != "1" ]; then
  say "start anvil fork on port $PORT"
  PORT="$PORT" script/dev/anvil.sh > "$(mktemp)" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 60); do cast chain-id --rpc-url "$E2E_RPC_URL" >/dev/null 2>&1 && break; sleep 1; done
fi
[ "$(cast chain-id --rpc-url "$E2E_RPC_URL" 2>/dev/null)" = "$CHAIN" ] || { echo "no chain $CHAIN node on $E2E_RPC_URL" >&2; exit 1; }

say "deploy (script/deploy.sh local)"
RPC_URL="$E2E_RPC_URL" script/deploy.sh local
CORE="$(jq -r .core $REC)"
CTL="$(jq -r .controller $REC)"

say "seed, PHASE=$PHASE"
for a in "$A1" "$A2" "$A3" "$KEEPER" "$TRADER"; do rpc anvil_setBalance "$a" "$FUND"; done
if [ -n "$DEV_WALLET" ]; then   # at least dev.walletEth; the owner already holds more after the deploy
  WANT="$(jq -r .dev.walletEth $CFG)"
  python3 -c "import sys; sys.exit(not int(sys.argv[1]) < int(sys.argv[2]))" "$(cast balance "$DEV_WALLET" --rpc-url "$E2E_RPC_URL")" "$WANT" && rpc anvil_setBalance "$DEV_WALLET" "$(cast to-hex "$WANT")"
fi
SEED="$(PHASE="$PHASE" CORE="$CORE" DEPLOYER="$OWNER" A1="$A1" A2="$A2" A3="$A3" TRADER="$TRADER" \
  forge script script/dev/Seed.s.sol --rpc-url "$E2E_RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
  || { echo "$SEED" | tail -40; echo "seed failed" >&2; exit 1; }
tmp="$(mktemp)"
jq --arg phase "$PHASE" --arg a1 "$A1" --arg a2 "$A2" --arg a3 "$A3" --arg k "$KEEPER" --arg t "$TRADER" --arg o "$DEV_WALLET" \
  '.accounts = ({a1: $a1, a2: $a2, a3: $a3, keeper: $k, trader: $t} + (if $o == "" then {} else {owner: $o} end)) | .phase = $phase' $REC > "$tmp" && mv "$tmp" $REC
if [ "$PHASE" = "post" ]; then
  pick() { printf '%s\n' "$SEED" | grep -oE "$1 0x[0-9a-fA-F]{40}" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
  TOKEN="$(pick BALANCE_TOKEN)"; MODULE="$(pick BALANCE_MODULE)"
  [ -n "$TOKEN" ] && [ -n "$MODULE" ] || { echo "$SEED" | tail -40; echo "no balance addresses from seed" >&2; exit 1; }
  jq --arg t "$TOKEN" --arg m "$MODULE" '.balanceToken = $t | .balanceModule = $m | .balancePool = {fee: 3000, tickSpacing: 60}' $REC > "$tmp" && mv "$tmp" $REC
  echo "balanceToken $TOKEN balanceModule $MODULE"
fi

declare -A GAS
finish() {
  say "gas per stage"
  for s in "${!GAS[@]}"; do echo "  $s: ${GAS[$s]}"; done | sort
  if [ "$KEEP" = "1" ]; then
    trap - EXIT
    echo
    echo "anvil left running on $E2E_RPC_URL (pid ${ANVIL_PID:-external}), record $ROOT/$REC"
  fi
  exit 0
}

stage() {
  local name="$1" out; out="$(mktemp)"
  say "stage $name"
  rm -f "broadcast/Scenario.s.sol/$CHAIN/run-latest.json"
  rpc evm_mine   # the stage simulation reads the node clock from the latest block
  if ! STAGE="$name" CORE="$CORE" OWNER="$OWNER" A1="$A1" A2="$A2" A3="$A3" KEEPER="$KEEPER" TRADER="$TRADER" DEV_WALLET="$DEV_WALLET" \
    forge script script/dev/Scenario.s.sol --rpc-url "$E2E_RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" > "$out" 2>&1; then
    echo "stage $name FAILED:"; tail -40 "$out"; exit 1
  fi
  awk '/^== Logs ==/{f=1;next} /^(Script ran|=====|##)/{f=0} f' "$out"
  GAS[$name]="$(python3 -c "import json; print(sum(int(r['gasUsed'], 16) for r in json.load(open('broadcast/Scenario.s.sol/$CHAIN/run-latest.json'))['receipts']))" 2>/dev/null || echo n/a)"
  if [ "${STOP_AFTER:-}" = "$name" ]; then echo "stopped after $name"; finish; fi
}

window() { call "$CTL" 'creditWindow()(uint32)' | awk '{print $1}'; }
# warps past the credit window, so the credits sold so far are composable
past_window() { warp $(($(window) + 60)); }

warp 2000   # past the anti sniper window
stage a
[ -z "$DEV_WALLET" ] || stage dev-wallet   # the dev wallet buys coin through the pool once the sniper window has passed
stage fill-a
stage adopt
past_window; stage compose-a
stage claims
stage d-open

say "the credit price falls over its window"
N="$(call "$CORE" 'pileSize()(uint256)' | awk '{print $1}')"
ID0="$(call "$CORE" 'pilePage(uint256,uint256)(uint256[])' 0 "$N" | tr ',' '\n' | tail -1 | grep -oE '[0-9]+' | head -1)"   # the newest credit, inside its window
P0="$(call "$CTL" 'creditPrice(uint256)(uint256)' "$ID0" | awk '{print $1}')"
warp 7200
P1="$(call "$CTL" 'creditPrice(uint256)(uint256)' "$ID0" | awk '{print $1}')"
echo "creditPrice of $ID0: $P0 then, $P1 two hours later"
[ "$(python3 -c "print(int($P1 < $P0))")" = 1 ] || { echo "CHECK FAILED: creditPrice did not fall" >&2; exit 1; }

stage d-buy
stage fill-b
past_window; stage compose-b
stage format
stage settings
stage pause
stage buyback

if [ "$PHASE" = "post" ]; then
  stage fill-d
  past_window; stage compose-d
  SID="$(call "$CORE" 'heldStatements()(uint256[])' | tr ',' '\n' | tail -1 | grep -oE '[0-9]+' | head -1)"
  say "warp until statement $SID reaches its floor"
  for i in $(seq 1 40); do
    [ "$(call "$CTL" 'atFloor(uint256)(bool)' "$SID")" = true ] && break
    warp 86400
  done
  [ "$(call "$CTL" 'atFloor(uint256)(bool)' "$SID")" = true ] || { echo "CHECK FAILED: statement $SID never reached its floor" >&2; exit 1; }
  stage redeem
  stage balance-bid
fi

stage fresh-fill
past_window; stage fresh-compose
stage report

say "LOCAL END TO END PASSED (PHASE=$PHASE)"
finish
