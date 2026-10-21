#!/usr/bin/env bash
# local end to end on an anvil mainnet fork: start anvil, deploy through script/deploy.sh, seed, run script/dev/Scenario.s.sol
# stage by stage with node time warps between them, and write the record deployments/<chainId>.json. a failed stage stops
# the run. every signer is an impersonated account (anvil --auto-impersonate, forge --unlocked).
#
#   PHASE=pre    the engine before the balance token: the module unset, balanceBidOn false, redeemOn as the config sets it (a redemption reverts NoBalanceModule).
#   PHASE=phase2 Seed deploys the standin balance token, the phase 2 treasury, the pro rata policy and ControllerV2,
#                selects them and turns every switch on (docs/RUNBOOK.md section 7, phase 2 locally)
#   BID=1        with PHASE=phase2: Seed adds the standing bid (an eth/standin pool, ControllerV2's reference on it,
#                StandingBidPolicy on the treasury and a bid budget); the record carries standingBidPolicy and the
#                stage standing-bid runs last, followed by a cast read that asserts a burn quotes the bid
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
BID="${BID:-0}"   # 1 adds the standing bid, phase2 only
export BID
case "$PHASE" in pre|post|phase2) ;; *) echo "PHASE must be pre, post or phase2, got $PHASE" >&2; exit 2 ;; esac
[ "$BID" != 1 ] || [ "$PHASE" = phase2 ] || { echo "BID=1 needs PHASE=phase2" >&2; exit 2; }

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
if [ "$PHASE" = "phase2" ]; then
  pick() { printf '%s\n' "$SEED" | grep -oEw "$1 0x[0-9a-fA-F]{40}" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
  TOKEN="$(pick BALANCE_TOKEN)"; MODULE="$(pick BALANCE_MODULE)"; V2="$(pick CONTROLLER_V2)"; POLICY="$(pick POLICY)"
  [ -n "$TOKEN" ] && [ -n "$MODULE" ] && [ -n "$V2" ] || { echo "$SEED" | tail -40; echo "no phase 2 addresses from seed" >&2; exit 1; }
  # the Core now points at ControllerV2: the record and every later stage read it
  CTL="$V2"
  jq --arg t "$TOKEN" --arg m "$MODULE" --arg c "$V2" --arg p "$POLICY" \
    '.controllerV1 = .controller | .controller = $c | .controllerV2 = $c | .balanceToken = $t | .balanceModule = $m | .redemptionPolicy = $p | .balancePool = null' $REC > "$tmp" && mv "$tmp" $REC
  echo "phase 2: balanceToken $TOKEN treasury $MODULE controllerV2 $V2 policy $POLICY"
  if [ "$BID" = 1 ]; then
    BID_POLICY="$(pick STANDING_BID_POLICY)"
    [ -n "$BID_POLICY" ] || { echo "$SEED" | tail -40; echo "no standing bid policy from seed" >&2; exit 1; }
    jq --arg b "$BID_POLICY" '.standingBidPolicy = $b | .redemptionPolicy = $b' $REC > "$tmp" && mv "$tmp" $REC
    echo "standing bid: policy $BID_POLICY (the pro rata policy $POLICY is no longer installed)"
  fi
fi
if [ "$PHASE" = "post" ]; then
  pick() { printf '%s\n' "$SEED" | grep -oEw "$1 0x[0-9a-fA-F]{40}" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
  TOKEN="$(pick BALANCE_TOKEN)"; MODULE="$(pick BALANCE_MODULE)"
  [ -n "$TOKEN" ] && [ -n "$MODULE" ] || { echo "$SEED" | tail -40; echo "no balance addresses from seed" >&2; exit 1; }
  TOPEN="$(printf '%s\n' "$SEED" | grep -oE 'OPENS_AT [0-9]+' | tail -1 | grep -oE '[0-9]+')"
  jq --arg t "$TOKEN" --arg m "$MODULE" '.balanceToken = $t | .balanceModule = $m | .balancePool = {fee: 3000, tickSpacing: 60}' $REC > "$tmp" && mv "$tmp" $REC
  echo "balanceToken $TOKEN balanceModule $MODULE opensAt ${TOPEN:-?}"
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

warp 4200   # past the anti sniper window
stage a
[ -z "$DEV_WALLET" ] || stage dev-wallet   # the dev wallet buys coin through the pool once the sniper window has passed
stage fill-a
stage adopt
past_window; stage compose-a
stage claims
stage d-open

say "the credit price holds at or above its floor as the bid climbs (decision 116)"
# creditPrice(id) = max(cost, valueOf(score)) * floorMultBps() / 10000, scaled up by the age curve to creditStartBps at
# acquisition. the floor tracks the climbing eth bid through valueOf, so the price rises with the bid; the invariant is
# that it never sits below that floor. compute the floor from the controller's getters and assert price >= floor.
CREDITS=0x97630aA70AB14ed9883B41dAfccBc11349723043
CREDIT_SCORE=0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7
N="$(call "$CORE" 'pileSize()(uint256)' | awk '{print $1}')"
ID0="$(call "$CORE" 'pilePage(uint256,uint256)(uint256[])' 0 "$N" | tr ',' '\n' | tail -1 | grep -oE '[0-9]+' | head -1)"   # the newest credit, inside its window
credit_floor() {   # the controller's creditPrice floor for credit $1 at the latest block
  local id="$1" cost seed paid score val fbps
  cost="$(call "$CORE" 'creditInfo(uint256)(bool,uint256,uint64)' "$id" | sed -n 2p | awk '{print $1}')"
  seed="$(call "$CREDITS" 'seedOf(uint256)(bytes21)' "$id" | awk '{print $1}')"
  paid="$(call "$CREDITS" 'timestampOf(uint256)(uint64)' "$id" | awk '{print $1}')"
  score="$(call "$CREDIT_SCORE" 'scoreOf(bytes21,uint64)(uint256)' "$seed" "$paid" | awk '{print $1}')"
  val="$(call "$CTL" 'valueOf(uint256)(uint256)' "$score" | awk '{print $1}')"
  fbps="$(call "$CTL" 'floorMultBps()(uint256)' | awk '{print $1}')"
  python3 -c "c=$cost; v=$val; print((c if c>v else v)*$fbps//10000)"
}
P0="$(call "$CTL" 'creditPrice(uint256)(uint256)' "$ID0" | awk '{print $1}')"; F0="$(credit_floor "$ID0")"
warp 7200
P1="$(call "$CTL" 'creditPrice(uint256)(uint256)' "$ID0" | awk '{print $1}')"; F1="$(credit_floor "$ID0")"
echo "creditPrice of $ID0: $P0 (floor $F0) then $P1 (floor $F1) two hours later"
[ "$(python3 -c "print(int($P0 >= $F0 and $P1 >= $F1))")" = 1 ] || { echo "CHECK FAILED: creditPrice fell below its floor" >&2; exit 1; }

stage d-buy
stage fill-b
past_window; stage compose-b
stage format
stage settings
stage pause
stage buyback

if [ "$PHASE" = "post" ] || [ "$PHASE" = "phase2" ]; then
  stage fill-d
  past_window; stage compose-d
  SID="$(call "$CORE" 'heldStatements()(uint256[])' | tr ',' '\n' | tail -1 | grep -oE '[0-9]+' | head -1)"
  say "warp until statement $SID reaches its floor"
  for i in $(seq 1 40); do
    [ "$(call "$CTL" 'atFloor(uint256)(bool)' "$SID")" = true ] && break
    warp 86400
  done
  [ "$(call "$CTL" 'atFloor(uint256)(bool)' "$SID")" = true ] || { echo "CHECK FAILED: statement $SID never reached its floor" >&2; exit 1; }
  # the redeem stage withdraws through Jack's token, which locks withdrawals and transfers until opensAt. advance node time to it
  if [ -n "${TOPEN:-}" ]; then
    CUR="$(cast block --field timestamp --rpc-url "$E2E_RPC_URL")"
    if [ "$CUR" -lt "$TOPEN" ]; then
      cast rpc evm_setNextBlockTimestamp "$TOPEN" --rpc-url "$E2E_RPC_URL" >/dev/null
      cast rpc evm_mine --rpc-url "$E2E_RPC_URL" >/dev/null
      echo "advanced node time to opensAt $TOPEN (from $CUR)"
    fi
  fi
  stage redeem
  stage balance-bid
fi

stage fresh-fill
past_window; stage fresh-compose
stage report

if [ "$BID" = 1 ]; then
  stage standing-bid
  say "the standing bid quotes above the share up to its capacity (decision 258)"
  # bidPerCC and bidCapacity from the policy, then the treasury's quote of a burn inside the capacity: it is the bid
  # for that burn less the redemption fee, above the proportional share of the claim reserve
  BIDP="$(jq -r .standingBidPolicy $REC)"
  PER="$(call "$BIDP" 'bidPerCC()(uint256,bool)' | sed -n 1p | awk '{print $1}')"
  USABLE="$(call "$BIDP" 'bidPerCC()(uint256,bool)' | sed -n 2p | awk '{print $1}')"
  CAP="$(call "$BIDP" 'bidCapacity()(uint256)' | awk '{print $1}')"
  X="$(python3 -c "print($CAP // 4)")"
  Q="$(call "$MODULE" 'quoteRedemption(uint256)(uint256,uint256,uint256,uint64,bool)' "$X" | sed -n 1p | awk '{print $1}')"
  EXEC="$(call "$MODULE" 'quoteRedemption(uint256)(uint256,uint256,uint256,uint64,bool)' "$X" | sed -n 5p | awk '{print $1}')"
  SHARE="$(call "$MODULE" 'redemptionTerms(uint256)(uint256,uint256,uint256)' "$X" | sed -n 1p | awk '{print $1}')"
  FEE="$(call "$MODULE" 'redemptionFeeBps()(uint16)' | awk '{print $1}')"
  WANT="$(python3 -c "print($X * $PER // 10**18 * (10000 - $FEE) // 10000)")"
  echo "standing bid: bidPerCC $PER (usable $USABLE) bidCapacity $CAP; a burn of $X quotes $Q (bid $WANT, share $SHARE, executable $EXEC)"
  [ "$USABLE" = true ] && [ "$EXEC" = true ] && [ "$Q" = "$WANT" ] && [ "$(python3 -c "print(int($Q > $SHARE))")" = 1 ] \
    || { echo "CHECK FAILED: the treasury's quote is not the standing bid" >&2; exit 1; }
fi

say "LOCAL END TO END PASSED (PHASE=$PHASE$([ "$BID" = 1 ] && echo " BID=1"))"
finish
