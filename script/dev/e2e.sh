#!/usr/bin/env bash
# local end to end on an anvil mainnet fork. starts (or reuses) anvil, deploys through the same path as mainnet
# (script/deploy.sh local), seeds, then runs the scenario stage by stage, warping the node between stages and checking
# after each. a failed stage or check stops the run with a clear message. no mainnet, no private key: anvil
# --auto-impersonate and --unlocked.
#
# PHASE selects how far the engine is driven:
#   PHASE=pre    the engine before the exit token exists: no exit module, exitMode 0. the coin trades, the eth bid, the
#                credit sale, composition, the statement sale, pause and the buyback all run.
#   PHASE=post   the exit side live too: exit module, exit pool key, exitMode 2, a statement redemption and the exit
#                token bid. this is the default.
# both phases end with live content: at least two statements for sale (one composed early, one composed last) and at
# least three pile credits of mixed window status. every user facing and keeper transaction type the engine has in its
# phase fires at least once, then the run prints an event inventory.
#
# migrate is excluded: it retires the engine, which would leave nothing for the UI to show.
# buyListing is not represented: the only local allowed target is the CreditStrategy, whose cheapest listing (0.036 eth)
# is about four times the rate cap, and the eth bid read is bounded by the cap, so no listing sits below the bid without
# distorting the rate settings; a Seaport order needs an externally signed listing that a bare fork cannot produce.
#
# the node is always the local anvil at E2E_RPC_URL (default http://127.0.0.1:8545). the shell RPC_URL is ignored so
# this never reaches a remote node.
#
#   script/dev/e2e.sh                               PHASE=post, a fresh anvil, run end to end, stop it
#   PHASE=pre script/dev/e2e.sh                     the pre exit engine
#   KEEP=1 script/dev/e2e.sh                        leave anvil running at the end for the UI, print the UI command
#   PORT=8546 E2E_RPC_URL=http://127.0.0.1:8546 script/dev/e2e.sh   a fresh anvil on 8546
#   NO_ANVIL=1 script/dev/e2e.sh                    reuse an anvil already on E2E_RPC_URL
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

E2E_RPC_URL="${E2E_RPC_URL:-http://127.0.0.1:8545}"
FORK_URL="${FORK_URL:-https://gateway.tenderly.co/public/mainnet}"
FORK_BLOCK="${FORK_BLOCK:-26158000}"
PORT="${PORT:-8545}"
PHASE="${PHASE:-post}"
KEEP="${KEEP:-0}"
case "$PHASE" in pre|post) ;; *) echo "PHASE must be pre or post, got $PHASE"; exit 2 ;; esac

OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
A1=0x1111111111111111111111111111111111111111
A2=0x2222222222222222222222222222222222222222
A3=0x3333333333333333333333333333333333333333
KEEPER=0x4444444444444444444444444444444444444444
TRADER=0x5555555555555555555555555555555555555555
FUND=0x152d02c7e14af6800000   # 100000 ether
# credit counts moved to the actors. A1 feeds every 80 credit fill (four composes in post), A2 the credit sale open and
# the statement buys, A3 adopt and the exit token sells.
N1="${N1:-330}"; N2="${N2:-10}"; N3="${N3:-10}"

say() { echo; echo "=== $* ==="; }
rpc() { cast rpc "$@" --rpc-url "$E2E_RPC_URL" >/dev/null; }
warp() { rpc evm_increaseTime "$1"; rpc evm_mine; }

ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

# ------------------------------------------------------------------ anvil

if [ "${NO_ANVIL:-0}" != "1" ]; then
  say "start anvil fork (block $FORK_BLOCK, chain 31337, port $PORT)"
  FORK_URL="$FORK_URL" FORK_BLOCK="$FORK_BLOCK" PORT="$PORT" "$ROOT/script/dev/anvil.sh" > /tmp/e2e-anvil.log 2>&1 &
  ANVIL_PID=$!
  for i in $(seq 1 60); do
    cast block-number --rpc-url "$E2E_RPC_URL" >/dev/null 2>&1 && break
    sleep 1
  done
  cast block-number --rpc-url "$E2E_RPC_URL" >/dev/null 2>&1 || { echo "anvil did not come up"; tail -20 /tmp/e2e-anvil.log; exit 1; }
fi

# the node must be the local fork before anything is sent
CID="$(cast chain-id --rpc-url "$E2E_RPC_URL")" || { echo "could not read the chain id from $E2E_RPC_URL"; exit 1; }
[ "$CID" = "31337" ] || { echo "e2e expects chain 31337 on $E2E_RPC_URL, got $CID"; exit 1; }

# ------------------------------------------------------------------ deploy (same path as mainnet)

say "deploy (script/deploy.sh local)"
RPC_URL="$E2E_RPC_URL" ./script/deploy.sh local
REC=deployments/31337.json
CORE="$(jq -r .core $REC)"
CTL="$(cast call "$CORE" 'controller()(address)' --rpc-url "$E2E_RPC_URL")"
ROUTER="$(cast call "$CORE" 'FEE_SOURCE()(address)' --rpc-url "$E2E_RPC_URL")"
DEPLOY_BLOCK="$(jq -r .block $REC)"
echo "core $CORE controller $CTL router $ROUTER (deploy block $DEPLOY_BLOCK)"

# ------------------------------------------------------------------ fund actors, seed

say "fund actors and seed credits and the exit stand ins"
for a in "$A1" "$A2" "$A3" "$KEEPER" "$TRADER"; do
  cast rpc anvil_setBalance "$a" "$FUND" --rpc-url "$E2E_RPC_URL" >/dev/null
done
SEED="$(N1=$N1 N2=$N2 N3=$N3 A1=$A1 A2=$A2 A3=$A3 DEPLOYER=$OWNER \
  forge script script/dev/Seed.s.sol --rpc-url "$E2E_RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
  || { echo "$SEED" | tail -40; echo "seed failed"; exit 1; }
EXIT_TOKEN="$(printf '%s\n' "$SEED" | grep -oE 'EXIT_TOKEN 0x[0-9a-fA-F]{40}' | tail -1 | grep -oE '0x[0-9a-fA-F]{40}')"
EXIT_MODULE="$(printf '%s\n' "$SEED" | grep -oE 'EXIT_MODULE 0x[0-9a-fA-F]{40}' | tail -1 | grep -oE '0x[0-9a-fA-F]{40}')"
[ -n "$EXIT_TOKEN" ] && [ -n "$EXIT_MODULE" ] || { echo "$SEED" | tail -40; echo "no exit addresses from seed"; exit 1; }
# the record carries the exit addresses only in post, where the engine points at them
if [ "$PHASE" = "post" ]; then
  tmp="$(mktemp)"; jq --arg t "$EXIT_TOKEN" --arg m "$EXIT_MODULE" '.exitToken=$t | .exitModule=$m' "$REC" > "$tmp" && mv "$tmp" "$REC"
  echo "exitToken $EXIT_TOKEN exitModule $EXIT_MODULE (written to $REC)"
else
  echo "exit stand ins deployed but not wired (PHASE=pre leaves exitMode 0)"
fi

# ------------------------------------------------------------------ scenario

declare -A GAS
stage() {
  local name="$1"
  local out; out="$(mktemp)"
  if ! STAGE="$name" CORE="$CORE" OWNER="$OWNER" A1="$A1" A2="$A2" A3="$A3" KEEPER="$KEEPER" TRADER="$TRADER" \
    EXIT_TOKEN="$EXIT_TOKEN" EXIT_MODULE="$EXIT_MODULE" \
    forge script script/dev/Scenario.s.sol --rpc-url "$E2E_RPC_URL" --broadcast --slow --unlocked --sender "$OWNER" \
    > "$out" 2>&1; then
    echo "stage $name FAILED:"; tail -40 "$out"; exit 1
  fi
  grep -E 'stage [a-z]|^  (fill-|adopt|compose-|d-|settings|pause|buyback|exit-|fresh-|report)|== final report|^  (ethPot|ethToBuyback|ethRedeemBurn|xPot|pileSize|heldStatements|coin totalSupply|floorRate|ethRate)' "$out" || true
  local f=broadcast/Scenario.s.sol/31337/run-latest.json
  if [ -f "$f" ]; then
    GAS[$name]="$(jq -r '.receipts[].gasUsed' "$f" 2>/dev/null | python3 -c 'import sys; print(sum(int(x,16) for x in sys.stdin.read().split()))' 2>/dev/null || echo n/a)"
  fi
}

creditWindow() { cast call "$CTL" 'creditWindow()(uint32)' --rpc-url "$E2E_RPC_URL" | awk '{print $1}'; }

say "warp past the anti sniper window / split start"
warp 2000

say "stage a: trade the coin, fees reach the core, the split starts"
stage a

say "stage fill-a: sell credits into the eth bid (batch and single)"
stage fill-a

say "stage adopt: credits sent straight to the engine"
stage adopt

say "stage compose-a: compose the default page, buy the statement"
stage compose-a

say "stage d-open: open the credit sale"
stage d-open

say "check the credit price falls over its window"
# cast annotates array elements with scientific notation (e.g. "[35960 [3.596e4]]"), so take the first integer token
CID0="$(cast call "$CORE" 'pilePage(uint256,uint256)(uint256[])' 0 1 --rpc-url "$E2E_RPC_URL" | grep -oE '[0-9]+' | head -1)"
P0="$(cast call "$CTL" 'creditPrice(uint256)(uint256)' "$CID0" --rpc-url "$E2E_RPC_URL" | awk '{print $1}')"
warp 7200
P1="$(cast call "$CTL" 'creditPrice(uint256)(uint256)' "$CID0" --rpc-url "$E2E_RPC_URL" | awk '{print $1}')"
echo "creditPrice id $CID0: before $P0 after 2h $P1"
python3 -c "import sys; sys.exit(0 if int('$P1')<int('$P0') else 1)" \
  || { echo "CHECK FAILED: creditPrice did not fall over the window"; exit 1; }

say "stage d-buy: buyCredit and buyCredits"
stage d-buy

say "stage fill-b: sell credits in, turn on chosen composition"
stage fill-b
say "warp past the credit window so the chosen page is ready"
warp 14410
say "stage compose-b: chosen composition"
stage compose-b

say "stage settings: owner changes that emit events"
stage settings

say "stage pause: pause then unpause"
stage pause

say "stage buyback: keeper buy and burn"
stage buyback

if [ "$PHASE" = "post" ]; then
  say "stage exit-setup: exit module, pool key, exitMode 2"
  stage exit-setup

  say "stage fill-d: fill the pile for the redemption statement"
  stage fill-d
  WIN="$(creditWindow)"; say "warp past the credit window ($WIN s)"; warp $((WIN + 60))
  say "stage compose-d: the redemption statement"
  stage compose-d

  say "warp until the redemption statement reaches its floor"
  SID="$(cast call "$CORE" 'heldStatements()(uint256[])' --rpc-url "$E2E_RPC_URL" | tr ',' '\n' | tail -1 | grep -oE '[0-9]+' | head -1)"
  AF=false
  for i in $(seq 1 40); do
    AF="$(cast call "$CTL" 'atFloor(uint256)(bool)' "$SID" --rpc-url "$E2E_RPC_URL")"
    [ "$AF" = "true" ] && break
    warp 86400
  done
  [ "$AF" = "true" ] || { echo "CHECK FAILED: statement $SID never reached its floor"; exit 1; }
  echo "statement $SID reached its floor after $i day-warps"

  say "stage exit-redeem: redeem, exit token bid, release the redeem burn"
  stage exit-redeem
fi

say "stage fresh-fill: fill the pile for the last statement"
stage fresh-fill
WIN="$(creditWindow)"; say "warp past the credit window ($WIN s)"; warp $((WIN + 60))
say "stage fresh-compose: the last statement, leave live pile content"
stage fresh-compose

say "stage report: final state"
stage report

say "gas per stage"
for s in a fill-a adopt compose-a d-buy fill-b compose-b settings pause buyback exit-setup fill-d compose-d exit-redeem fresh-fill fresh-compose; do
  [ -n "${GAS[$s]:-}" ] && echo "  $s: ${GAS[$s]}"
done

say "event inventory"
# scan from the fork block so the deploy and resume events (ControllerSet, EngineSet, PayeesSet, SplitStartSet) are
# counted too; the contracts did not exist before the fork, so only their own events appear
RPC_URL="$E2E_RPC_URL" FROM_BLOCK="$FORK_BLOCK" CORE="$CORE" CTL="$CTL" ROUTER="$ROUTER" PHASE="$PHASE" \
  "$ROOT/script/dev/event-inventory.sh"

say "LOCAL END TO END PASSED (PHASE=$PHASE)"

if [ "$KEEP" = "1" ]; then
  trap - EXIT
  echo
  echo "anvil left running on $E2E_RPC_URL (pid ${ANVIL_PID:-external}). the record is $REC."
  echo "point the UI at it:"
  echo "  cd <ui worktree>/web && RECORD=\$(pwd)/../../$(basename "$ROOT")/$REC npm run dev:local"
  echo "stop anvil with: kill ${ANVIL_PID:-<pid>}"
fi
