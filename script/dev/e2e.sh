#!/usr/bin/env bash
# local end to end on an anvil mainnet fork. starts (or reuses) anvil, deploys
# through the same path as mainnet (script/deploy.sh local), seeds, then runs the
# scenario stage by stage, warping the node between stages and checking after
# each. a failed stage or check stops the run with a clear message. no mainnet,
# no private key: anvil --auto-impersonate and --unlocked.
#
#   script/dev/e2e.sh          start a fresh anvil, run end to end, stop it
#   NO_ANVIL=1 script/dev/e2e.sh   reuse an anvil already on $RPC_URL
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
FORK_URL="${FORK_URL:-https://gateway.tenderly.co/public/mainnet}"
FORK_BLOCK="${FORK_BLOCK:-26158000}"
PORT="${PORT:-8545}"

OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
A1=0x1111111111111111111111111111111111111111
A2=0x2222222222222222222222222222222222222222
A3=0x3333333333333333333333333333333333333333
KEEPER=0x4444444444444444444444444444444444444444
TRADER=0x5555555555555555555555555555555555555555
FUND=0x152d02c7e14af6800000   # 100000 ether

say() { echo; echo "=== $* ==="; }
rpc() { cast rpc "$@" --rpc-url "$RPC_URL" >/dev/null; }
warp() { rpc evm_increaseTime "$1"; rpc evm_mine; }

ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

# ------------------------------------------------------------------ anvil

if [ "${NO_ANVIL:-0}" != "1" ]; then
  say "start anvil fork (block $FORK_BLOCK, chain 31337)"
  FORK_URL="$FORK_URL" FORK_BLOCK="$FORK_BLOCK" PORT="$PORT" "$ROOT/script/dev/anvil.sh" > /tmp/e2e-anvil.log 2>&1 &
  ANVIL_PID=$!
  for i in $(seq 1 60); do
    cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
    sleep 1
  done
  cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 || { echo "anvil did not come up"; tail -20 /tmp/e2e-anvil.log; exit 1; }
fi

# ------------------------------------------------------------------ deploy (same path as mainnet)

say "deploy (script/deploy.sh local)"
RPC_URL="$RPC_URL" ./script/deploy.sh local
REC=deployments/31337.json
CORE="$(jq -r .core $REC)"
echo "core $CORE"

# ------------------------------------------------------------------ fund actors, seed

say "fund actors and seed credits and the exit stand ins"
for a in "$A1" "$A2" "$A3" "$KEEPER" "$TRADER"; do
  cast rpc anvil_setBalance "$a" "$FUND" --rpc-url "$RPC_URL" >/dev/null
done
SEED="$(A1=$A1 A2=$A2 A3=$A3 DEPLOYER=$OWNER \
  forge script script/dev/Seed.s.sol --rpc-url "$RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
  || { echo "$SEED" | tail -40; echo "seed failed"; exit 1; }
EXIT_TOKEN="$(printf '%s\n' "$SEED" | grep -oE 'EXIT_TOKEN 0x[0-9a-fA-F]{40}' | tail -1 | grep -oE '0x[0-9a-fA-F]{40}')"
EXIT_MODULE="$(printf '%s\n' "$SEED" | grep -oE 'EXIT_MODULE 0x[0-9a-fA-F]{40}' | tail -1 | grep -oE '0x[0-9a-fA-F]{40}')"
[ -n "$EXIT_TOKEN" ] && [ -n "$EXIT_MODULE" ] || { echo "$SEED" | tail -40; echo "no exit addresses from seed"; exit 1; }
tmp="$(mktemp)"; jq --arg t "$EXIT_TOKEN" --arg m "$EXIT_MODULE" '.exitToken=$t | .exitModule=$m' "$REC" > "$tmp" && mv "$tmp" "$REC"
echo "exitToken $EXIT_TOKEN exitModule $EXIT_MODULE (written to $REC)"

# ------------------------------------------------------------------ scenario

declare -A GAS
stage() {
  local name="$1"
  local out; out="$(mktemp)"
  if ! STAGE="$name" CORE="$CORE" OWNER="$OWNER" A1="$A1" A2="$A2" A3="$A3" KEEPER="$KEEPER" TRADER="$TRADER" \
    EXIT_TOKEN="$EXIT_TOKEN" EXIT_MODULE="$EXIT_MODULE" \
    forge script script/dev/Scenario.s.sol --rpc-url "$RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" \
    > "$out" 2>&1; then
    echo "stage $name FAILED:"; tail -40 "$out"; exit 1
  fi
  grep -E 'stage [a-z]|== final report|^  (ethPot|ethToBuyback|ethRedeemBurn|xPot|pileSize|heldStatements|coin totalSupply|floorRate|ethRate)' "$out" || true
  local f=broadcast/Scenario.s.sol/31337/run-latest.json
  if [ -f "$f" ]; then
    GAS[$name]="$(jq -r '.receipts[].gasUsed' "$f" 2>/dev/null | python3 -c 'import sys; print(sum(int(x,16) for x in sys.stdin.read().split()))' 2>/dev/null || echo n/a)"
  fi
}

say "warp past the anti sniper window / split start"
warp 2000

say "stage a: trade the coin, fees reach the core"
stage a

say "stage b: sell 80 credits into the eth bid"
stage b

say "warp past the credit window so compose is ready"
warp 14410

say "stage c: compose and buy the statement"
stage c

say "stage d: open the credit sale, sell fresh credits in"
DOPEN="$(STAGE=d-open CORE=$CORE OWNER=$OWNER A1=$A1 A2=$A2 A3=$A3 KEEPER=$KEEPER TRADER=$TRADER \
  forge script script/dev/Scenario.s.sol --rpc-url "$RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
  || { echo "$DOPEN" | tail -30; echo "stage d-open FAILED"; exit 1; }
printf '%s\n' "$DOPEN" | sed -n '/stage/p'
CREDIT_ID="$(printf '%s\n' "$DOPEN" | grep -oE 'fresh credit id [0-9]+' | tail -1 | grep -oE '[0-9]+$')"
P0="$(cast call "$(cast call $CORE 'controller()(address)' --rpc-url $RPC_URL)" 'creditPrice(uint256)(uint256)' "$CREDIT_ID" --rpc-url $RPC_URL | awk '{print $1}')"
warp 7200
CTL="$(cast call $CORE 'controller()(address)' --rpc-url $RPC_URL)"
P1="$(cast call "$CTL" 'creditPrice(uint256)(uint256)' "$CREDIT_ID" --rpc-url $RPC_URL | awk '{print $1}')"
echo "creditPrice id $CREDIT_ID: before $P0 after 2h $P1"
python3 -c "import sys; p0=int('$P0'); p1=int('$P1'); sys.exit(0 if p1<p0 else 1)" \
  || { echo "CHECK FAILED: creditPrice did not fall over the window"; exit 1; }

say "stage d-buy: buyCredit and buyCredits"
stage d-buy

say "stage e: chosen composition"
stage e-fill
warp 15000
stage e-compose

say "stage f: pause then unpause"
stage f

say "stage g: keeper buyback (buy and burn)"
stage g

say "stage h: exit side"
stage h-setup
say "warp until the held statement reaches its floor"
CTL="$(cast call "$CORE" 'controller()(address)' --rpc-url "$RPC_URL")"
SID="$(cast call "$CORE" 'heldStatements()(uint256[])' --rpc-url "$RPC_URL" | sed 's/[][]//g' | tr ',' '\n' | tail -1 | tr -d ' ')"
AF=false
for i in $(seq 1 40); do
  AF="$(cast call "$CTL" 'atFloor(uint256)(bool)' "$SID" --rpc-url "$RPC_URL")"
  [ "$AF" = "true" ] && break
  warp 86400
done
[ "$AF" = "true" ] || { echo "CHECK FAILED: statement $SID never reached its floor"; exit 1; }
echo "statement $SID reached its floor after $i day-warps"
stage h-redeem

say "stage i: final report"
stage report

say "gas per stage"
for s in a b c d-buy e-fill e-compose f g h-setup h-redeem; do
  echo "  $s: ${GAS[$s]:-n/a}"
done

say "LOCAL END TO END PASSED"
