#!/usr/bin/env bash
# activity speed run against the already running local chain: rounds of realistic trading, sweeping, selling, composing
# and buying through the real doors, with node time warps between rounds so the bid climbs and the sale prices decay.
# it reads the deployment record, never deploys, seeds or resets, and refuses a node that is not local or whose chain id differs from the record's (31337, or 1 on a chain id 1 fork).
#
#   script/dev/activity.sh eth [rounds]       default 5 rounds
#   script/dev/activity.sh balance [rounds]   eth rounds plus the balance side (needs the post phase module)
#   script/dev/activity.sh both [rounds]      eth rounds, then balance rounds
#
#   SEED=<n>            reproducible run (printed at the start otherwise)
#   PAUSE=1             wait for Enter between rounds
#   RECORD=<file>       deployment record, default deployments/31337.json (its rpcUrl is the node)
#   RPC_URL=<url>       override the node
#   WARP_MIN, WARP_MAX  seconds warped before each round, default 7200 and 14400
#   BOT_MARGIN=<wei>    least gap between a listing price and the bid for the bot, default 0.001 ether
#   PEOPLE, PEOPLE_CREDITS   most holders, and most credits per holder, in the people stage, default 5 and 3
#   OPENSEA_API_KEY     fetches the active Credits listings from OpenSea once per run (script/dev/opensea-listings.mjs)
#   SEAPORT_ORDERS=<file>   a file in the format of that script, used instead of the fetch
#   QUIET=1             print the round summary only
#
# one forge run per round (script/dev/Activity.s.sol `round`), one `discover` run per run, a cache per core in
# script/dev/.cache (strategy listings, real holders).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

MODE="${1:-}"
ROUNDS="${2:-5}"
case "$MODE" in eth | balance | both) ;; *) echo "usage: $0 eth|balance|both [rounds]" >&2; exit 2 ;; esac
case "$ROUNDS" in '' | *[!0-9]*) echo "rounds must be a number" >&2; exit 2 ;; esac

REC="${RECORD:-deployments/31337.json}"
[ -f "$REC" ] || { echo "no deployment record at $REC, run script/dev/local.sh first" >&2; exit 1; }
RPC="${RPC_URL:-$(jq -r .rpcUrl "$REC")}"
CHAIN="$(jq -r .chainId "$REC")"
case "$CHAIN" in 1 | 31337) ;; *) echo "the record is chain id $CHAIN, expected 31337 or 1 (a local fork)" >&2; exit 1 ;; esac
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "$CHAIN" ] || { echo "no chain id $CHAIN node on $RPC" >&2; exit 1; }
case "$RPC" in http://127.0.0.1:* | http://localhost:*) ;; *) echo "the node must be local, got $RPC" >&2; exit 1 ;; esac
CORE="$(jq -r .core "$REC")"
CTL="$(jq -r .controller "$REC")"
COIN="$(jq -r .coin "$REC")"
OWNER="$(jq -r .owner "$REC")"
SEAPORT_ADAPTER="$(jq -r .seaportAdapter "$REC")"
SEED="${SEED:-$(($(date +%s) % 1000000))}"
WARP_MIN="${WARP_MIN:-7200}"
WARP_MAX="${WARP_MAX:-14400}"
CACHE=script/dev/.cache
CACHEF="$CACHE/activity-$CORE.json"
BCAST="broadcast/Activity.s.sol/$CHAIN/round-latest.json"
mkdir -p "$CACHE"
RUNDIR="$(mktemp -d "$ROOT/$CACHE/run.XXXXXX")"   # under the repo: forge reads files only below it
cleanup() {
  cast rpc anvil_removeBlockTimestampInterval --rpc-url "$RPC" > /dev/null 2>&1 || true
  [ "${KEEP_RUN:-0}" = 1 ] || rm -rf "$RUNDIR"
}
trap cleanup EXIT
TALLY="$RUNDIR/tally.json"
echo '{"count":{},"last":{}}' > "$TALLY"
export SEED RECORD="$REC"
[ "$MODE" = eth ] || export HOLD_BACK=2   # statements the buyers leave for the redemptions

call() { cast call "$@" --rpc-url "$RPC"; }
num() { call "$@" | awk '{print $1}'; }
rpc() { cast rpc "$@" --rpc-url "$RPC" > /dev/null; }
# block time advances one second per block while the run lasts, so the quotes the forge simulation reads stay current
# when its transactions are mined; a warp sets the next block timestamp
warp() { rpc evm_setNextBlockTimestamp $(($(cast block latest --rpc-url "$RPC" -f timestamp) + $1)); rpc evm_mine; }
eth() { cast from-wei "$1" | awk '{printf "%.4f", $1}'; }
say() { echo; echo "=== $* ==="; }
fails=0

forge_run() { # <outfile> <forge script args...>
  local out="$1"; shift
  forge script script/dev/Activity.s.sol:Activity "$@" --rpc-url "$RPC" --unlocked --sender "$OWNER" > "$out" 2>&1
}
logs() { awk '/^== Logs ==/{f=1;next} /^(Script ran|=====|##)/{f=0} f' "$1" | sed '/^$/d'; }

# ---------------------------------------------------------------------------------------------------------------------
# once per run: build, the OpenSea fetch, the read-only discovery
say "seed $SEED, node $RPC, core $CORE"
rpc anvil_setBlockTimestampInterval 1
forge build > "$RUNDIR/build.log" 2>&1 || { tail -30 "$RUNDIR/build.log"; echo "forge build failed" >&2; exit 1; }

ALL="$CACHE/opensea-$CORE-${SEAPORT_CATCHUP:-0}.json"   # the fetch, reused for an hour unless REFRESH=1
if [ -n "${SEAPORT_ORDERS:-}" ]; then
  cp "$SEAPORT_ORDERS" "$RUNDIR/seaport-all.json"; ALL="$RUNDIR/seaport-all.json"
elif [ -n "${OPENSEA_API_KEY:-}" ]; then
  if [ "${REFRESH:-0}" = 1 ] || [ -z "$(find "$ALL" -mmin -60 2> /dev/null)" ]; then
    FORK_HORIZON="$([ "${SEAPORT_CATCHUP:-0}" = 1 ] && echo 1000000000 || echo $((5 * WARP_MAX)))" node script/dev/opensea-listings.mjs --out "$ALL" --rpc "$RPC" --adapter "$SEAPORT_ADAPTER" --fulfiller "$(cast keccak "$(cast abi-encode 'f(string,string,uint256)' cc-speedrun bot 0)" | sed 's/0x.\{24\}/0x/')" \
      || { echo "opensea fetch failed, continuing without listings"; echo '{"count":0,"orders":[]}' > "$ALL"; }
  else
    echo "opensea: using the fetch of the last hour ($(jq .count "$ALL") signed listings)"
  fi
else
  echo "opensea: OPENSEA_API_KEY and SEAPORT_ORDERS are unset, no Seaport listings"
  ALL="$RUNDIR/seaport-all.json"; echo '{"count":0,"orders":[]}' > "$ALL"
fi

if [ "${SEAPORT_CATCHUP:-0}" = 1 ] && [ "$(jq .count "$ALL")" != 0 ]; then   # open every listed order on the fork
  t="$(jq '[.orders[].params.startTime | tonumber] | max' "$ALL")"
  now="$(cast block latest --rpc-url "$RPC" -f timestamp)"
  if [ "$t" -gt "$now" ]; then echo "seaport: warping $((t - now + 60)) s so the listed orders have started"; warp $((t - now + 60)); fi
fi
if [ ! -f "$CACHEF" ]; then
  if ! DISCOVER=listings,holders forge_run "$RUNDIR/discover.log" --sig 'discover()'; then
    tail -30 "$RUNDIR/discover.log"; echo "discover failed" >&2; exit 1
  fi
  python3 - "$RUNDIR/discover.log" "$CACHEF" << 'PY'
import json, re, sys
ids, prices, scores, holders, holdings = [], [], [], [], []
owned = {}
for line in open(sys.argv[1]):
    m = re.match(r"\s*LISTING\s+(\d+)\s+(\d+)\s+(\d+)", line)
    if m:
        ids.append(m.group(1)); prices.append(m.group(2)); scores.append(m.group(3))
    m = re.match(r"\s*HOLDER\s+(0x[0-9a-fA-F]{40})\s+(\d+)", line)
    if m:
        owned.setdefault(m.group(1), []).append(int(m.group(2)))
holders = list(owned)
holdings = [owned[h] for h in holders]
json.dump({"ids": ids, "prices": prices, "scores": scores, "holders": holders, "holdings": holdings}, open(sys.argv[2], "w"))
PY
fi
echo "cache: $(jq '.ids | length' "$CACHEF") strategy listings, $(jq '.holders | length' "$CACHEF") real holders"
export CACHE_FILE="$CACHEF" SEAPORT_FILE="$ALL"

# ---------------------------------------------------------------------------------------------------------------------
tally() { # adds the broadcast of the last round to the run tally
  python3 - "$BCAST" "$TALLY" << 'PY'
import json, sys
kinds = {"execute": "swap", "sellForEth": "sellForEth", "sellForBalance": "sellForBalance", "buyListing": "sweep",
         "compose": "compose", "buy": "statementBuy", "buyCredit": "creditBuy", "buyCredits": "creditBuy",
         "buyback": "buyback", "redeemStatement": "redeem", "book": "book"}
try:
    txs = json.load(open(sys.argv[1]))["transactions"]
except Exception:
    txs = []
t = json.load(open(sys.argv[2]))
for x in txs:
    k = kinds.get((x.get("function") or "").split("(")[0])
    if k:
        t["count"][k] = t["count"].get(k, 0) + 1
        t["last"][k] = x["hash"]
json.dump(t, open(sys.argv[2], "w"))
PY
}

summary() {
  local round="$1" ceth burn sold
  sold="$(cast logs --from-block "$(jq -r .deployBlock "$REC")" --address "$CTL" 'Bought(uint256,address,uint256)' --rpc-url "$RPC" | grep -c blockNumber || true)"
  burn="$(python3 - "$RPC" "$COIN" "$(jq -r .deployBlock "$REC")" << 'PY'
import json, sys, urllib.request
rpc, coin, from_block = sys.argv[1:4]
sig = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
body = {"jsonrpc": "2.0", "id": 1, "method": "eth_getLogs", "params": [{"fromBlock": hex(int(from_block)), "toBlock": "latest", "address": coin, "topics": [sig, None, "0x" + "0" * 64]}]}
r = json.load(urllib.request.urlopen(urllib.request.Request(rpc, json.dumps(body).encode(), {"content-type": "application/json"})))
print(sum(int(l["data"], 16) for l in r["result"]) // 10**18)
PY
)"
  say "round $round summary"
  echo "pot            $(eth "$(num "$CORE" 'ethPot()(uint256)')") eth"
  echo "bid            $(eth "$(num "$CORE" 'ethRate()(uint256)')") eth for a reference credit"
  echo "pile           $(num "$CORE" 'pileSize()(uint256)') credits"
  echo "held           $(call "$CORE" 'heldStatements()(uint256[])' | tr -d '[]' | awk -F, '{print ($0 == "" ? 0 : NF)}') statements"
  echo "sold           $sold statements (all runs)"
  echo "cc burned      $burn CC (all runs)"
  if [ "$(call "$CORE" 'balanceModule()(address)')" != 0x0000000000000000000000000000000000000000 ]; then
    echo "balance rate   $(python3 -c "print(f'{$(num "$CORE" 'balanceRate()(uint256)')/100:.2f}% of par')")  module available $(num "$(call "$CORE" 'balanceModule()(address)')" 'available()(uint256)')"
  fi
  echo "actions (this run): $(jq -r '.count | to_entries | map("\(.key) \(.value)") | join(", ")' "$TALLY")"
  jq -r --arg c "$CHAIN" '.last | to_entries[] | "  last \(.key): https://evm.now/tx/\(.value)?chainId=\($c)"' "$TALLY"
}

warp_for_balance() { # warps until a held statement reaches its floor, at most 12 times
  local sid held
  for _ in $(seq 1 12); do
    held="$(call "$CORE" 'heldStatements()(uint256[])' | tr -d '[]' | tr ',' ' ')"
    [ -n "${held// /}" ] || { echo "no statement is held, nothing to redeem this round"; return 0; }
    for sid in $held; do
      [ "$(call "$CTL" 'atFloor(uint256)(bool)' "$sid")" = true ] && return 0
    done
    warp 21600
  done
  echo "no held statement reached its floor after 72 hours of warps" >&2
}

round() { # <n> <withBalance>
  local n="$1" bal="$2" w out="$RUNDIR/round-$1-$2.log" t0
  w=$((WARP_MIN + (SEED * 7919 + n * 104729) % (WARP_MAX - WARP_MIN + 1)))
  say "round $n ($([ "$bal" = true ] && echo balance || echo eth)), warp $w s"
  warp "$w"
  [ "$bal" = true ] && warp_for_balance
  t0=$SECONDS
  rm -f "$BCAST"
  if ! ROUND="$n" forge_run "$out" --sig 'round(bool)' "$bal" --broadcast; then
    tail -40 "$out"; echo "round $n FAILED" >&2; fails=$((fails + 1)); return 0
  fi
  [ "${QUIET:-0}" = 1 ] || logs "$out"
  tally
  echo "round $n took $((SECONDS - t0)) s"
  summary "$n"
  if [ "${PAUSE:-0}" = 1 ]; then read -r -p "round $n done, Enter for the next " _ < /dev/tty; fi
}

n=0
if [ "$MODE" = eth ] || [ "$MODE" = both ]; then
  for _ in $(seq 1 "$ROUNDS"); do n=$((n + 1)); round "$n" false; done
fi
if [ "$MODE" = balance ] || [ "$MODE" = both ]; then
  [ "$(call "$CORE" 'balanceModule()(address)')" != 0x0000000000000000000000000000000000000000 ] || { echo "balance rounds need the module set (the post phase)" >&2; exit 1; }
  for _ in $(seq 1 "$ROUNDS"); do n=$((n + 1)); round "$n" true; done
fi
say "activity done, seed $SEED, rounds failed $fails"
[ "$fails" = 0 ]
