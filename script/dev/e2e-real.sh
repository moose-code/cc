#!/usr/bin/env bash
# The full launch end to end on a local chain id 1 anvil fork of mainnet, with nothing faked: the real deploy and seed,
# real pool swaps pushing fee income through the hook, the real keeper binary (keeper/src/main.ts) as the only engine
# caller for the keeper doors, real EIP-712 Seaport orders, the owner's real phase 2 and value mode calls. Every phase
# asserts on chain reads and prints PASS/FAIL; the run exits nonzero on any FAIL. The keeper and the anvil this script
# starts are stopped on exit. Total wall time is printed.
#
# Chain id 1 so Seaport accepts the OpenSea-style signatures. The fork is https://gateway.tenderly.co/public/mainnet at
# latest minus 100, built once (deploy local + Seed PHASE=pre) and saved with anvil_dumpState keyed on the contract,
# deploy and seed sources (not the phase logic), so reruns load the state in seconds. The first run pays the fork.
#
#   script/dev/e2e-real.sh            build or load the cache, run every phase, stop anvil and the keeper
#   FRESH=1 script/dev/e2e-real.sh    ignore the cache and rebuild the deployed and seeded state
#   FORK_URL=<archive rpc> ...        the default is the Tenderly public gateway
#   KEEP=1 ...                        leave anvil running after the run
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

START_TS=$(date +%s)
PORT="${PORT:-8620}"            # never 8545, which other dev flows own
RPC="http://127.0.0.1:$PORT"
FORK_URL="${FORK_URL:-https://gateway.tenderly.co/public/mainnet}"
CACHE_DIR="script/dev/.cache"
REC="deployments/1.json"
OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
A1=0x1111111111111111111111111111111111111111
A2=0x2222222222222222222222222222222222222222
A3=0x3333333333333333333333333333333333333333
TRADER=0x5555555555555555555555555555555555555555
FUNDER=0x6666666666666666666666666666666666666666   # surrenders Jack's launch page (production phase 6)
STATEMENTS=0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b
STRATEGY_ADDR=0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6
FUND=0x152d02c7e14af6800000   # 100000 ether
LISTED_A=35377; LISTED_B=28352; LISTED_C=18683
mkdir -p "$CACHE_DIR"

FAILS=0
PASSES=0
SCRATCH="$(mktemp -d)"
ANVIL_PID=""
KEEPER_LOG="$CACHE_DIR/e2e-real-keeper.log"   # gitignored, persists past cleanup for inspection

cleanup() {
  [ -n "$ANVIL_PID" ] && [ "${KEEP:-0}" != "1" ] && kill "$ANVIL_PID" 2>/dev/null
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

say() { echo; echo "=== $* ==="; }
rpc() { cast rpc "$@" --rpc-url "$RPC" >/dev/null; }
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
callc() { cast call "$@" --rpc-url "$RPC"; }
num() { callc "$@" | awk '{print $1}'; }
# a true/false assertion: check "<label>" <0|1> "<detail>"
check() {
  if [ "$2" = 1 ]; then echo "  PASS: $1 ($3)"; PASSES=$((PASSES + 1));
  else echo "  FAIL: $1 ($3)"; FAILS=$((FAILS + 1)); fi
}
# PASS when $1 (a python bool expression over shell-substituted numbers) is true
calc() { python3 -c "import sys; print(1 if ($1) else 0)"; }
# runs a forge E2EReal step; returns its stdout, fails the run on a revert
step() {
  local sig="$1"; shift
  local out; out="$SCRATCH/step.log"
  if ! CORE="$CORE" OWNER="$OWNER" A1="$A1" A2="$A2" A3="$A3" TRADER="$TRADER" E2E_RPC_URL="$RPC" \
    forge script script/dev/E2EReal.s.sol --sig "$sig" "$@" \
    --rpc-url "$RPC" --chain-id 1 --broadcast --slow --unlocked --sender "$OWNER" >"$out" 2>&1; then
    echo "  STEP FAILED: $sig"; tail -30 "$out"; FAILS=$((FAILS + 1)); return 1
  fi
  awk '/^== Logs ==/{f=1;next} /^(Script ran|=====|##|If you wish)/{f=0} f' "$out"
  return 0
}

# ---- anvil with the dump/load cache -------------------------------------------------------------------------------

# the state depends on the contracts, the deploy path and the seed, not the phase logic or this script
KEY="$({
  git ls-files src script/Deploy.s.sol script/Preflight.s.sol script/Postflight.s.sol script/Checks.sol \
    script/deploy.sh script/dev/Seed.s.sol script/config/anvil.json script/env/local.env foundry.toml remappings.txt \
    test/standins test/utils 2>/dev/null | sort | while read -r f; do [ -f "$f" ] && shasum "$f"; done
} | shasum | cut -c1-12)"
STATE="$CACHE_DIR/e2e-real-state-$KEY.hex"
RECORD="$CACHE_DIR/e2e-real-record-$KEY.json"
BLOCKF="$CACHE_DIR/e2e-real-block-$KEY.txt"

say "start anvil (chain id 1) on port $PORT"
if lsof -ti "tcp:$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is in use; stop it or set PORT" >&2; exit 1; fi

if [ "${FRESH:-0}" != "1" ] && [ -f "$STATE" ] && [ -f "$RECORD" ] && [ -f "$BLOCKF" ]; then
  BLOCK="$(cat "$BLOCKF")"
  echo "cache hit: key $KEY, fork block $BLOCK"
  anvil --fork-url "$FORK_URL" --fork-block-number "$BLOCK" --chain-id 1 --port "$PORT" \
    --auto-impersonate --retries 10 --timeout 60000 >"$SCRATCH/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
  printf '{"jsonrpc":"2.0","id":1,"method":"anvil_loadState","params":["%s"]}' "$(cat "$STATE")" \
    | curl -sf -X POST -H 'content-type: application/json' --data-binary @- "$RPC" >/dev/null
  jq --arg u "$RPC" '.rpcUrl = $u' "$RECORD" > "$REC"
else
  echo "cache miss: key $KEY, building the deployed and seeded state"
  # FORK_BLOCK pins the fork so the cache compounds across runs and a cold run is deterministic. the deploy predicts the
  # Core, coin and renderer at CREATE2 addresses; the live protocol occupies them at recent head blocks, so a head fork
  # collides. the default pins the cold-audit block, which predates those deployments. unset FORK_BLOCK to track head.
  BLOCK="${FORK_BLOCK:-26208025}"
  [ "$BLOCK" = head ] && BLOCK=$(( $(cast block-number --rpc-url "$FORK_URL") - 100 ))
  echo "fork block $BLOCK"
  anvil --fork-url "$FORK_URL" --fork-block-number "$BLOCK" --chain-id 1 --port "$PORT" \
    --auto-impersonate --retries 10 --timeout 60000 >"$SCRATCH/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 90); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
  [ "$(cast chain-id --rpc-url "$RPC")" = "1" ] || { echo "anvil did not start as chain id 1"; tail -20 "$SCRATCH/anvil.log"; exit 1; }
  # the live owner keeps its mainnet 7702 delegation on the fork: Preflight pins that delegation, the delegate code hash
  # and an empty key registry, and the delegation only runs on inbound calls, so impersonated owner sends are unaffected
  rpc anvil_setBalance "$OWNER" "$FUND"

  say "deploy (script/deploy.sh local, chain id 1)"
  RPC_URL="$RPC" CHAIN_ID=1 script/deploy.sh local || { echo "deploy failed"; exit 1; }

  say "seed PHASE=pre (credits to A1/A2/A3 and the owner, no fund, no setRate)"
  for a in "$A1" "$A2" "$A3" "$TRADER"; do rpc anvil_setBalance "$a" "$FUND"; done
  CORE="$(jq -r .core "$REC")"
  if ! PHASE=pre CORE="$CORE" DEPLOYER="$OWNER" A1="$A1" A2="$A2" A3="$A3" TRADER="$TRADER" \
    forge script script/dev/Seed.s.sol --rpc-url "$RPC" --chain-id 1 --broadcast --slow --unlocked --sender "$OWNER" \
    >"$SCRATCH/seed.log" 2>&1; then tail -40 "$SCRATCH/seed.log"; echo "seed failed"; exit 1; fi
  jq --arg a1 "$A1" --arg a2 "$A2" --arg a3 "$A3" --arg t "$TRADER" --arg o "$OWNER" \
    '.accounts = {a1:$a1,a2:$a2,a3:$a3,keeper:"",trader:$t,owner:$o} | .phase="pre"' "$REC" > "$SCRATCH/rec.json" && mv "$SCRATCH/rec.json" "$REC"

  cast rpc anvil_dumpState --rpc-url "$RPC" | tr -d '"' > "$STATE"
  cp "$REC" "$RECORD"
  echo "$BLOCK" > "$BLOCKF"
  echo "saved cache $STATE"
fi

[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "1" ] || { echo "no chain id 1 node on $RPC"; exit 1; }
CORE="$(jq -r .core "$REC")"
CTL="$(jq -r .controller "$REC")"
CREDITS=0x97630aA70AB14ed9883B41dAfccBc11349723043
RATE_START=4900000000000000
RATE_CAP=14700000000000000

# ---- the keeper (real binary, throwaway keystore outside the repo) -------------------------------------------------

KEYSTORE_DIR="$SCRATCH/keeper-keystore"
PW_FILE="$SCRATCH/keeper-pw"
echo "e2e-real-keeper" > "$PW_FILE"
KEEPER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # throwaway, anvil default #0 key, never funds mainnet
cast wallet import e2e-real-keeper --keystore-dir "$KEYSTORE_DIR" --private-key "$KEEPER_PK" --unsafe-password "$(cat "$PW_FILE")" >/dev/null 2>&1
KEEPER_KS="$KEYSTORE_DIR/e2e-real-keeper"
KEEPER_ADDR="$(cast wallet address --private-key "$KEEPER_PK")"
rpc anvil_setBalance "$KEEPER_ADDR" "$FUND"
jq --arg k "$KEEPER_ADDR" '.accounts.keeper = $k' "$REC" > "$SCRATCH/rec.json" && mv "$SCRATCH/rec.json" "$REC"
echo "keeper $KEEPER_ADDR, keystore $KEEPER_KS"

# one real tick of the keeper binary; extra env in KEEPER_ENV (space separated KEY=VAL). the next block is mined at 1
# gwei so the keeper's per door base fee ceilings (3 to 5 gwei) let its transactions land on a mainnet fork
keeper_once() {
  cast rpc anvil_setNextBlockBaseFeePerGas 0x3b9aca00 --rpc-url "$RPC" >/dev/null 2>&1
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null 2>&1
  env RECORD="$REC" RPC_URLS="$RPC" KEYSTORE="$KEEPER_KS" KEYSTORE_PASSWORD_FILE="$PW_FILE" \
    STATE_DIR="$SCRATCH/keeper-state" LISTING_DELAY_SEC=0 RPC_TIMEOUT_MS=60000 \
    STRATEGY_IDS="$LISTED_A,$LISTED_B,$LISTED_C" ${KEEPER_ENV:-} \
    node keeper/src/main.ts --once >>"$KEEPER_LOG" 2>&1 || true
}
# steps `n` blocks of 12 s, running the keeper tick each
keeper_run() {
  local n="$1"
  for _ in $(seq 1 "$n"); do keeper_once; warp 12; done
}
# true when the Core owns credit $1
core_owns() {
  [ "$(callc "$CREDITS" 'ownerOf(uint256)(address)' "$1" 2>/dev/null | tr 'A-Z' 'a-z')" = "${CORE,,}" ] && echo 1 || echo 0
}

############################################################################## phase 1
say "PHASE 1: launch"
P1="$(step "phase1Settings()")"; echo "$P1" | sed 's/^/    /'
check "ethPot is 0 at launch" "$(calc "$(num "$CORE" 'ethPot()(uint256)') == 0")" "pot $(num "$CORE" 'ethPot()(uint256)')"
check "ethRate is 0 (empty pot clamps the bid)" "$(calc "$(num "$CORE" 'ethRate()(uint256)') == 0")" "rate $(num "$CORE" 'ethRate()(uint256)')"
check "RATE_START is 4.9e15" "$(calc "$(num "$CORE" 'RATE_START()(uint256)') == $RATE_START")" "$(num "$CORE" 'RATE_START()(uint256)')"
P1CAP="$(echo "$P1" | grep -m1 'phase1: rateCap' | awk '{print $NF}')"
check "rateCap is 1.47e16" "$(calc "'$P1CAP' == '$RATE_CAP'")" "$P1CAP"
MOD="$(callc "$CORE" 'balanceModule()(address)' | tr 'A-Z' 'a-z')"
check "balance module is zero" "$([ "$MOD" = 0x0000000000000000000000000000000000000000 ] && echo 1 || echo 0)" "$MOD"

############################################################################## phase 2
say "PHASE 2: real fee income through the hook (10 buys, 5 sells, inside the sniper window)"
BAL0="$(cast balance "$CORE" --rpc-url "$RPC")"
step "phase2Swaps(uint256,uint256)" 10 5 || true
BAL1="$(cast balance "$CORE" --rpc-url "$RPC")"
POT1="$(num "$CORE" 'ethPot()(uint256)')"
check "Core balance grew from the hook pushes" "$(calc "$BAL1 > $BAL0")" "before $BAL0 after $BAL1"
check "no door booked (pot still 0)" "$(calc "$POT1 == 0")" "pot $POT1"
say "step 10 minutes in 60 s blocks, no engine call"
for _ in $(seq 1 10); do warp 60; done
RATE2="$(num "$CORE" 'ethRate()(uint256)')"
check "ethRate climbs above 4.9e15 from unbooked income (decision 147)" "$(calc "$RATE2 > $RATE_START")" "rate $RATE2"

############################################################################## phase 3
say "PHASE 3: the keeper books, sweeps a strategy listing, the rate drops"
STRATEGY=0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6
# warp so the bid climbs toward the cap, so a strategy listing (35377) sits under the bid within the keeper window
warp 28800   # 8 hours idle
BIDA="$(num "$CORE" "bidOf(uint256)(uint256)" "$LISTED_A")"
PRICEA="$(num "$STRATEGY" 'nftForSale(uint256)(uint256)' "$LISTED_A" 2>/dev/null || echo 0)"
echo "  listing $LISTED_A bid $BIDA price $PRICEA"
RATE_PRE="$(num "$CORE" 'ethRate()(uint256)')"
: > "$KEEPER_LOG"
keeper_run 15
POT3="$(num "$CORE" 'ethPot()(uint256)')"
RATE_POST="$(num "$CORE" 'ethRate()(uint256)')"
check "the keeper booked (pot > 0)" "$(calc "$POT3 > 0")" "pot $POT3"
check "the keeper bought the strategy listing $LISTED_A (ListingBought)" "$(core_owns "$LISTED_A")" "owner $(callc "$CREDITS" 'ownerOf(uint256)(address)' "$LISTED_A" 2>/dev/null)"
check "the keeper logged a confirmed buyListing" "$(grep -q '"door":"buyListing"' "$KEEPER_LOG" && echo 1 || echo 0)" "keeper log"
check "ethRate dropped on the fill" "$(calc "$RATE_POST < $RATE_PRE")" "pre $RATE_PRE post $RATE_POST"

############################################################################## phase 4
say "PHASE 4: listings, sellers, the return lock, the reserve"
# two signed Seaport orders 10 percent under the bid, filled by the keeper through the Seaport adapter
ORDERS="$SCRATCH/orders.json"
if RECORD="$REC" RPC="$RPC" OUT="$ORDERS" COUNT=2 node script/dev/make-seaport-orders.mjs >"$SCRATCH/orders.log" 2>&1; then
  SP_ID0="$(grep -m1 '^ORDER id' "$SCRATCH/orders.log" | awk '{print $3}')"
  : > "$KEEPER_LOG"
  # STRATEGY_IDS=off so only the Seaport source is active: the listed credits also sit in the strategy watch set, and a
  # strategy entry for an id the strategy no longer holds would shadow its Seaport order (as seaport.e2e isolates)
  KEEPER_ENV="STRATEGY_IDS=off SEAPORT_ORDERS=$ORDERS DOORS=buyListing" keeper_run 8
  check "the keeper filled a signed Seaport order $SP_ID0" "$(core_owns "$SP_ID0")" "owner $(callc "$CREDITS" 'ownerOf(uint256)(address)' "$SP_ID0" 2>/dev/null)"
else
  echo "  could not build Seaport orders"; tail -15 "$SCRATCH/orders.log"; FAILS=$((FAILS + 1))
fi
# a direct eth sell from A1 pays exactly bidOf at the fill block
if step "phase4DirectSell()"; then check "direct sellForEth paid exactly bidOf" 1 "see step log"; fi
# a credit sale buyer from A2, then the return lock refuses A2 inside 6 h and allows A3 after a transfer
BOUGHT="$(step "phase4CreditBuy()" | grep -m1 'BOUGHT_CREDIT' | awk '{print $2}')"
if [ -n "$BOUGHT" ]; then
  check "A2 bought a credit through the sale" 1 "credit $BOUGHT"
  if step "phase4ReturnLock(uint256)" "$BOUGHT"; then check "the return lock refuses A2 and allows A3 after transfer" 1 "credit $BOUGHT"; fi
else
  echo "  credit sale buy failed"; FAILS=$((FAILS + 1))
fi
# the reserve: with the pot at or under 0.1 eth plus queued payments, sellForEth reverts PotTooSmall
if step "phase4Reserve()"; then check "sellForEth reverts with the reserve error at the reserve" 1 "PotTooSmall"; fi

############################################################################## phase 5
say "PHASE 5: a page composes, the statement sells, a buyback burns CC"
step "phase5FillPile()" || true
PILE="$(num "$CORE" 'pileSize()(uint256)')"
check "the pile holds a composable page" "$(calc "$PILE >= 80")" "pile $PILE"
# warp past the credit window, then the keeper composes
WIN="$(num "$CTL" 'creditWindow()(uint32)')"
warp $((WIN + 60))
: > "$KEEPER_LOG"
KEEPER_ENV="DOORS=compose" keeper_run 6
check "the keeper composed a page (Composed)" "$(grep -q '"door":"compose"' "$KEEPER_LOG" && echo 1 || echo 0)" "keeper log"
# the statement sale split to the artist, operator and buyback
if step "phase5Buy()"; then check "the statement sale split to artist, operator and buyback" 1 "see step log"; fi
# the buyback burns CC
COIN="$(jq -r .coin "$REC")"
SUP0="$(num "$COIN" 'totalSupply()(uint256)')"
: > "$KEEPER_LOG"
warp 60
KEEPER_ENV="DOORS=buyback" keeper_run 6
SUP1="$(num "$COIN" 'totalSupply()(uint256)')"
check "a buyback burned CC" "$(calc "$SUP1 < $SUP0")" "supply $SUP0 -> $SUP1"
check "the payee share latched after the sniper window" "$(callc "$CORE" 'payeeOn()(bool)' | grep -q true && echo 1 || echo 0)" "payeeOn"

############################################################################## phase 6
say "PHASE 6: phase 2 balance side (the owner's real calls on Jack's pinned contracts)"
# the artifact is required: no mock fallback on any phase 2 path (owner directive)
[ -f out/upstream-balance.json ] || { echo "  FAIL: out/upstream-balance.json missing; run script/tools/upstream-balance.sh" >&2; exit 1; }
BTOK=""; BMOD=""
echo "  >>> wiring Jack's pinned contracts from out/upstream-balance.json"
# the funder, the strategy and the Statements owner send directly on the node (not forge broadcast), so fund their gas
rpc anvil_setBalance "$FUNDER" "$FUND"
rpc anvil_setBalance "$STRATEGY_ADDR" "$FUND"
rpc anvil_setBalance "$(callc "$STATEMENTS" 'owner()(address)')" "$FUND"
OUT6="$(step "phase6ProdDeploy()")" && {
  BTOK="$(echo "$OUT6" | grep -m1 'BALANCE_TOKEN' | awk '{print $2}')"
  BMOD="$(echo "$OUT6" | grep -m1 'BALANCE_MODULE' | awk '{print $2}')"
  TOPEN="$(echo "$OUT6" | grep -m1 'TRANSFERS_OPEN_BLOCK' | awk '{print $2}')"
}
check "the owner set the production balance module (Jack's pinned build)" "$([ -n "$BMOD" ] && echo 1 || echo 0)" "module $BMOD"
if [ -n "$BTOK" ]; then
  jq --arg t "$BTOK" --arg m "$BMOD" '.balanceToken=$t|.balanceModule=$m' "$REC" > "$SCRATCH/rec.json" && mv "$SCRATCH/rec.json" "$REC"
  # A1 fills a page for the redemption; compose waits for the credit window
  step "phase6ProdFill()" || true
  PILE6="$(num "$CORE" 'pileSize()(uint256)')"
  check "phase 6 pile holds a composable page" "$(calc "$PILE6 >= 80")" "pile $PILE6"
  WIN6="$(num "$CTL" 'creditWindow()(uint32)')"
  warp $((WIN6 + 60))
  RSID="$(step "phase6ProdCompose()" | grep -m1 'REDEEM_SID' | awk '{print $2}')"
  check "phase 6 composed a held statement" "$([ -n "$RSID" ] && echo 1 || echo 0)" "statement $RSID"
  if [ -n "$RSID" ]; then
    # mine to Jack's opening block, then warp the statement to its redemption floor
    CUR="$(cast block-number --rpc-url "$RPC")"
    if [ -n "$TOPEN" ] && [ "$CUR" -lt "$TOPEN" ]; then
      cast rpc anvil_mine "$(printf '0x%x' $((TOPEN - CUR + 1)))" --rpc-url "$RPC" >/dev/null
    fi
    for _ in $(seq 1 40); do
      [ "$(callc "$CTL" 'atFloor(uint256)(bool)' "$RSID")" = true ] && break
      warp 86400
    done
    check "phase 6 statement reached its floor" "$([ "$(callc "$CTL" 'atFloor(uint256)(bool)' "$RSID")" = true ] && echo 1 || echo 0)" "atFloor $RSID"
    if step "phase6ProdRedeem(uint256)" "$RSID"; then check "redeem at the floor pays rating times 1e14 into the module" 1 "see step log"; fi
    ART="$(callc "$CORE" 'artist()(address)')"
    royalty_held() { echo $(( $(num "$BTOK" 'balanceOf(address)(uint256)' "$ART") + $(num "$BMOD" 'owed(address)(uint256)' "$ART") )); }
    ROY0="$(royalty_held)"
    if step "phase6BalanceSell()"; then
      check "a balance sell pays balanceBidOf and the bid stays under par" 1 "see step log"
      PAID6="$(grep -m1 'balanceBidOf / paid' "$SCRATCH/step.log" | awk '{print $(NF-1)}')"
      # the royalty is the artist's token balance plus its owed amount in the module (launch buyToArtistBps 250)
      check "the balance sell royalty reached the artist or is owed to the artist" \
        "$(calc "$(royalty_held) - $ROY0 == $PAID6 * 250 // 10000")" "royalty held $(royalty_held) before $ROY0 bid $PAID6"
    fi
  fi
fi

############################################################################## phase 7
say "PHASE 7: value mode"
if [ -n "$BTOK" ]; then
  # Jack's token reaches holders through the module (A1's phase 6 balance sell) and the funder's launch balance. the
  # funder moves about 2 percent of supply to the liquidity wallet after transfersOpenBlock and adds a full-range
  # position, so the balance pool carries real trading depth. value mode then runs the full pool-move stress: a quote
  # gated on that depth, an 8 percent spot move, a sell inside the bands, the keeper refresh cadence, and a same-block
  # round trip that nets at most zero after pool fees. phase 6 already mined past transfersOpenBlock for the redemption.
  OUT7L="$(step "phase7ProdLiquidity(address)" "$BTOK")"; echo "$OUT7L" | sed 's/^/    /'
  DEPTH="$(echo "$OUT7L" | grep -m1 'POOL_DEPTH' | awk '{print $2}')"
  MOVED="$(echo "$OUT7L" | grep -m1 'MOVED_TOKENS' | awk '{print $2}')"
  check "the funder seeded real balance-pool depth" "$([ -n "$DEPTH" ] && calc "$DEPTH > 0")" "depth $DEPTH moved $MOVED"
  # the minLiquidity gate at half the seeded depth: usable now, and an 8 percent price move keeps full-range L in place
  MINLIQ="$(python3 -c "print(${DEPTH:-0}//2)")"
  if step "phase7Quote(uint128)" "$MINLIQ"; then check "value mode is on with the quote set" 1 "referencePrice $(num "$CTL" 'referencePrice()(uint256)')"; fi
  step "phase7MovePool(address)" "$BTOK" || true
  : > "$KEEPER_LOG"
  KEEPER_ENV="DOORS=refreshReference" keeper_once; warp 601
  KEEPER_ENV="DOORS=refreshReference" keeper_once; warp 601
  KEEPER_ENV="DOORS=refreshReference" keeper_once
  REFRESHES="$(grep -c '"door":"refreshReference"' "$KEEPER_LOG" 2>/dev/null | tr -d '[:space:]')"
  check "the keeper refreshed the reference on cadence" "$(calc "$REFRESHES >= 1")" "$REFRESHES refresh ticks"
  if step "phase7ValueSell()"; then check "a value mode sell pays inside the bands" 1 "see step log"; fi
  OUT7RT="$(step "phase7RoundTrip(address)" "$BTOK")"; echo "$OUT7RT" | sed 's/^/    /'
  RT_LOSS="$(echo "$OUT7RT" | grep -m1 'RT_POOL_LOSS' | awk '{print $2}')"
  check "no profitable same-block round trip (loses the pool fee)" "$([ -n "$RT_LOSS" ] && calc "$RT_LOSS > 0")" "pool loss $RT_LOSS"
  RATE_ON="$(num "$CORE" 'ethRate()(uint256)')"
  step "phase7ValueOff()" || true
  RATE_OFF="$(num "$CORE" 'ethRate()(uint256)')"
  check "the eth instance resets near the shared rate at switch off" \
    "$(python3 -c "o=$RATE_ON; f=$RATE_OFF; print(1 if abs(f-o) <= o*3//100 + 1 else 0)")" "on $RATE_ON off $RATE_OFF"
else
  echo "  phase 6 did not wire the balance side; value mode skipped"; FAILS=$((FAILS + 1))
fi

############################################################################## result
WALL=$(( $(date +%s) - START_TS ))
say "RESULT"
echo "passes: $PASSES   fails: $FAILS   wall: ${WALL}s"
[ "${KEEP:-0}" = 1 ] && { trap - EXIT; rm -rf "$SCRATCH"; echo "anvil left running on $RPC (pid $ANVIL_PID)"; }
[ "$FAILS" -eq 0 ] || exit 1
echo "E2E-REAL PASSED"
