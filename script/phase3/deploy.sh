#!/usr/bin/env bash
# the phase 3 owner sequence (docs/STATUS.md section 1, docs/specs/PHASE3.md) from one command:
#
#   cd /Users/dd/CascadeProjects/cc/cc && script/phase3/deploy.sh
#
# order: 1 deploy, 2 migrate and its readback, 5 ens, 6 readback, then 4 bid
# once its spender activation has passed, then the live readback. every sending step is the repository's own script:
# a dry run first (no keystore, --sender the owner, no --broadcast) that must exit 0 with no FAIL row and the expected
# transaction count, then the same step with --broadcast --slow --account ripe0x after the owner types yes.
# what is done is read from the chain on every run, so running the same command again continues: a finished step is
# skipped, and a step whose sends stopped partway is offered as `forge script --resume` (docs/STATUS.md: a run that
# stops partway resumes with --resume --slow, never a fresh run, because Phase3.s.sol's previews refuse a half done
# state). deployments/1-phase3.json holds the five addresses; it is written from the deploy's `record:` line.
# no key, password or API key is read or passed here: foundry prompts for the keystore password itself. every chain
# call goes to the one RPC below; a 429 on a read or dry run waits and retries the same endpoint, a broadcast is never
# retried by this script.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd -P)"
RPC=https://mainnet.gateway.tenderly.co
OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
ACCOUNT=ripe0x
CORE=0xcdb1889ae12074d750CD9B8531B692015465e0dD
V1=0xB85CF439Ca57b4bfC28fA1Cb8a97Ee85555B0496
ENS_REGISTRY=0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e
VAULT_NODE=0xafdad34bdab44b570b0fafbb86b35b5647eb86dfbd34357f594e910ca745415d
REC=deployments/1-phase3.json
P3=script/Phase3.s.sol:Phase3
LOGS=cache/phase3
READBACK_ROWS=40
# the v1 custody and claim reserve the rehearsal moved (docs/STATUS.md 2026-10-26); a live value further than 1 BALANCE
# from these stops the migrate, since every bucket the readback reports derives from them
WANT_CUSTODY=570081549034400000000000
WANT_RESERVE=57037287580000000000000
WANT_AVAILABLE=513044261454400000000000
SPENDER_TUPLE="(bool,bool,uint16,uint64,uint40,uint40,uint128,uint128,uint128,uint128,uint128,uint256,uint256,uint256)"
RERUN="cd $ROOT && script/phase3/deploy.sh"
WHERE=checks
mkdir -p "$LOGS"

# the variables the steps read come only from this script
unset STEP LIVE SEND SETTINGS_PATCH SET_RATE CONTROLLER TREASURY_V2 CONTROLLER_V3 MARKET_REDEEMER CREDIT_BID
for v in $(compgen -e | grep '^SET_' || true); do unset "$v"; done
export CORE

stop() {
  echo
  echo "STOPPED at step $WHERE: $*"
  echo "Nothing more is sent. Once the cause is understood, run the same command again:"
  echo
  echo "  $RERUN"
  exit 1
}

lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
is429() { grep -qiE 'too many requests|rate.?limit|error code 429|http error 429|status code 429' "$1"; }

# cast with a 429 retry on the same endpoint; prints the raw answer
c() {
  local out i
  for i in 1 2 3 4 5 6; do
    if out=$(cast "$@" --rpc-url "$RPC" 2>&1); then printf '%s\n' "$out"; return 0; fi
    printf '%s' "$out" | grep -qiE 'too many requests|rate.?limit|429' || { echo "$out" >&2; return 1; }
    echo "the gateway answered 429, waiting $((i * 10)) s" >&2
    sleep $((i * 10))
  done
  echo "$out" >&2
  return 1
}
word() { awk '{print $1}'; }
# two wei amounts within about 1 BALANCE of each other, compared in whole tokens (bash integers stop at 9.2e18)
near() {
  local a b
  a=$(cast from-wei "$1")
  b=$(cast from-wei "$2")
  a=${a%%.*}
  b=${b%%.*}
  [ $((a - b)) -le 1 ] && [ $((b - a)) -le 1 ]
}
# field n (1 based) of a tuple answer such as "(true, false, 2500 [2.5e3], ...)"
field() { tr -d '()' | awk -F', ' -v n="$1" '{print $n}' | word; }

# forge script against the RPC as the owner. $1 the log, the rest forge arguments. a dry run retries a 429
fs() {
  local log=$1 rc i
  shift
  for i in 1 2 3 4 5; do
    set +e
    forge script "$@" --rpc-url "$RPC" --sender "$OWNER" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" = 0 ] && return 0
    case " $* " in *" --broadcast "*) return "$rc" ;; esac
    is429 "$log" || return "$rc"
    echo "the gateway answered 429, waiting $((i * 15)) s, same endpoint"
    sleep $((i * 15))
  done
  return 1
}

why() { grep -E 'Error|error:|revert|ChecksFailed|^[[:space:]]*FAIL  |^[[:space:]]*failed: ' "$1" | tail -6 || true; }

no_fail() {
  if grep -qE '^[[:space:]]*FAIL  ' "$1"; then stop "the run printed FAIL rows:
$(grep -E '^[[:space:]]*FAIL  ' "$1")"; fi
}

# the log printed a table of `n of n checks passed`
table_ok() {
  grep -qE "^[[:space:]]*$2 of $2 checks passed" "$1" || stop "the $3 table did not pass $2 of $2: $(grep -E 'checks passed' "$1" | head -1)"
}

rows_ok() {
  no_fail "$1"
  grep -qE "^[[:space:]]*$READBACK_ROWS of $READBACK_ROWS checks passed" "$1" \
    || stop "the readback did not pass $READBACK_ROWS of $READBACK_ROWS: $(grep -E 'checks passed' "$1" | tail -1)"
}

# the dry run of one step: exit 0, no FAIL row, exactly `want` transactions
dry() {
  local script=$1 want=$2 ref=$3 log="$LOGS/$WHERE-dry-$(date +%s).log" n json est
  DRY_LOG=$log
  json="broadcast/$(basename "${script%%:*}")/1/dry-run/run-latest.json"
  rm -f "$json"
  echo
  echo "== $WHERE: dry run (no keystore, nothing sent)"
  fs "$log" "$script" || stop "the dry run exited nonzero: $(why "$log")"
  no_fail "$log"
  n=$(jq '.transactions | length' "$json" 2>/dev/null || true)
  [ "$n" = "$want" ] || stop "the dry run prepared ${n:-no} transactions, expected $want"
  echo
  est=$(grep -E 'Estimated total gas used' "$log" | tail -1 | awk '{print $NF}')
  echo "$WHERE: $n transaction(s) prepared. forge estimates $est gas with its 130 percent limit multiplier, so about"
  echo "$((est * 10 / 13)) used (rehearsal: $ref). $(grep -E 'Estimated amount required' "$log" | tail -1 | sed 's/^ *//')"
}

# the owner's yes, read from the terminal
yes_or_exit() {
  local ans=""
  send_guard
  echo
  read -r -p "Type yes to send $WHERE with the ripe0x keystore, anything else stops: " ans </dev/tty || ans=""
  if [ "$ans" != yes ]; then
    echo "Nothing sent. Run the same command again when ready:"
    echo
    echo "  $RERUN"
    exit 0
  fi
}

# a send runs from the main checkout at origin/main with no transaction of the owner in flight (AGENTS.md)
send_guard() {
  git fetch -q origin main || stop "git fetch origin main failed"
  [ "$(git branch --show-current)" = main ] || stop "sends run from the main checkout, this checkout is on $(git branch --show-current)"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || stop "main is not origin/main. Bring it up to date with: git pull --ff-only origin main"
  [ -z "$(git status --porcelain -- . ":(exclude)$REC")" ] || stop "the checkout has changes besides $REC:
$(git status --porcelain -- . ":(exclude)$REC")"
  [ "$(c nonce --block pending "$OWNER")" = "$(c nonce "$OWNER")" ] || stop "a transaction from the owner is still pending. Wait for it to land"
}

# the broadcast of the dry run just shown, or with --resume the remaining sends of the stopped run
send() {
  local script=$1 log="$LOGS/$WHERE-send-$(date +%s).log"
  shift
  send_guard
  echo
  echo "== $WHERE: sending (foundry asks for the keystore password)"
  if ! fs "$log" "$script" --broadcast --slow --account "$ACCOUNT" "$@"; then
    write_record "$log"
    stop "the send exited nonzero: $(why "$log")
$(is429 "$log" && echo 'the gateway answered 429 during the send.')
The chain decides what landed. The next run reads it and offers forge --resume for the rest."
  fi
  write_record "$log"
}

# deployments/1-phase3.json from the deploy's record line, as soon as a deploy send has printed it
write_record() {
  [ "$WHERE" = deploy ] || return 0
  local r
  r=$(grep -oE 'record: \{.*\}' "$1" | tail -1 | sed 's/^record: //') || true
  [ -n "$r" ] || return 0
  jq -n --argjson r "$r" --arg core "$CORE" '{chainId: 1, core: $core, proRataRedeemer: $r.redeemer,
    treasuryV2: $r.treasuryV2, controllerV3: $r.controllerV3, marketRedeemer: $r.marketRedeemer,
    creditBid: $r.creditBid, deployBlock: null}' >"$REC"
  echo "wrote $REC"
}

ADDRS=(proRataRedeemer treasuryV2 controllerV3 marketRedeemer creditBid)
addr() { jq -r ".$1" "$REC"; }

# done: all five have code. none: nothing landed and the owner's next nonce still creates the first one. else partial
deploy_state() {
  local k n=0
  for k in "${ADDRS[@]}"; do [ "$(c code "$(addr "$k")")" != 0x ] && n=$((n + 1)); done
  if [ "$n" = 5 ]; then echo done
  elif [ "$n" = 0 ] && [ "$(lc "$(c compute-address "$OWNER" --nonce "$(c nonce "$OWNER")" | awk '{print $NF}')")" = "$(lc "$(addr proRataRedeemer)")" ]; then echo none
  else echo partial; fi
}

# the first block where the ProRataRedeemer has code
deploy_block() {
  local lo=26274000 hi mid at
  hi=$(c block-number)
  at=$(addr proRataRedeemer)
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    if [ "$(c code --block "$mid" "$at")" = 0x ]; then lo=$mid; else hi=$mid; fi
  done
  echo "$hi"
}

# forge --resume of the last Phase3.s.sol broadcast, after checking it is the stopped step's own
resume() {
  local want=$1 first=$2 f=broadcast/Phase3.s.sol/1/run-latest.json
  [ -f "$f" ] || stop "$WHERE stopped partway but $f is missing, so there is nothing to resume from. Reconcile the receipts by hand"
  [ "$(jq '.transactions | length' "$f")" = "$want" ] || stop "$f is not the $WHERE run ($(jq '.transactions | length' "$f") transactions, $WHERE has $want)"
  [ "$(lc "$(jq -r '.transactions[0].transaction.to // .transactions[0].contractAddress // empty' "$f")")" = "$(lc "$first")" ] \
    || stop "$f does not start with the $WHERE run's first transaction"
  echo
  echo "$WHERE stopped partway. The rest of that same run is sent with forge --resume; nothing is sent twice."
  yes_or_exit
  send "$P3" --resume
}

# --- checks
[ "$(c chain-id)" = 1 ] || stop "the RPC is not chain 1"
[ "$(lc "$(c call "$CORE" 'owner()(address)')")" = "$(lc "$OWNER")" ] || stop "the Core owner is not $OWNER"
forge --version | grep -q '1.8.1' || stop "foundry 1.8.1 is required (docs/STATUS.md section 5)"
[ -z "${FOUNDRY_PROFILE:-}" ] || stop "FOUNDRY_PROFILE is set; the pinned builds are the default profile"

# --- 1 deploy
WHERE=deploy
if [ -f "$REC" ] && [ "$(deploy_state)" = none ]; then
  echo "nothing from the recorded deploy landed; deploying afresh"
  rm "$REC"
fi
if [ ! -f "$REC" ]; then
  echo "== deploy: out/ against the pinned build hashes"
  MAINNET_RPC_URL=$RPC forge test --match-path test/BuildIdentity.t.sol || stop "test/BuildIdentity.t.sol failed: out/ is not the pinned build"
  export STEP=deploy
  dry "$P3" 5 "11,327,948 gas"
  table_ok "$DRY_LOG" 4 "deploy preview"
  grep -qF 'ok    preview: band (1+step)(1+tol)(1-margin) < 1  |  300' "$DRY_LOG" \
    || stop "the deploy preview's band row does not read the reference step 300"
  yes_or_exit
  send "$P3"
fi
[ -f "$REC" ] || stop "the deploy printed no record line"
if [ "$(deploy_state)" = partial ]; then
  export STEP=deploy
  resume 5 "$(addr proRataRedeemer)"
  [ "$(deploy_state)" = done ] || stop "after the resume the five contracts still do not all have code"
fi
if [ "$(jq -r .deployBlock "$REC")" = null ]; then
  jq --argjson b "$(deploy_block)" '.deployBlock = $b' "$REC" >"$REC.tmp" && mv "$REC.tmp" "$REC"
fi
echo "deploy: done, $REC:"
cat "$REC"
export TREASURY_V2 CONTROLLER_V3 MARKET_REDEEMER CREDIT_BID
TREASURY_V2=$(addr treasuryV2)
CONTROLLER_V3=$(addr controllerV3)
MARKET_REDEEMER=$(addr marketRedeemer)
CREDIT_BID=$(addr creditBid)

readback() {
  local log="$LOGS/readback$1-$(date +%s).log"
  echo
  echo "== readback${1:+ (LIVE=1)}: $WHERE"
  export STEP=readback
  if [ -n "$1" ]; then export LIVE=1; else unset LIVE; fi
  fs "$log" "$P3" || stop "the readback exited nonzero: $(why "$log")"
  unset LIVE
  rows_ok "$log"
  echo
  echo "readback: $READBACK_ROWS of $READBACK_ROWS. Expected: v2 custody about 570,081 BALANCE, pro-rata bucket about 57,037"
  echo "(the v1 claim reserve), bid and redeemer 2 buckets 0 until their step (decision 295), the bid bucket the whole"
  echo "surplus above the cushion after the bid step (decision 298), cushion 150,000, floor ask 0.008961 ETH, V3 quote step 300, floor multiplier 13,750 (the Core's cap"
  echo "stays 11,000: step 3 is dropped, decision 296)."
}

# --- 2 migrate. done: the Core's controller is V3 (the last of its 18 sends). not started: v1 is the module with its
# switches on. anything between is a migrate that stopped partway
WHERE=migrate
MIGRATED_NOW=0
ctl=$(c call "$CORE" 'controller()(address)')
mod=$(c call "$CORE" 'balanceModule()(address)')
if [ "$(lc "$ctl")" != "$(lc "$CONTROLLER_V3")" ]; then
  export STEP=migrate
  if [ "$(lc "$mod")" = "$(lc "$V1")" ] && [ "$(c call "$V1" 'conversionEnabled()(bool)')" = true ] \
    && [ "$(c call "$V1" 'workingPaymentsEnabled()(bool)')" = true ]; then
    custody=$(c call "$V1" 'custody()(uint256)' | word)
    reserve=$(c call "$V1" 'claimReserve()(uint256)' | word)
    near "$custody" "$WANT_CUSTODY" && near "$reserve" "$WANT_RESERVE" \
      || stop "v1 custody $custody and claim reserve $reserve differ from the rehearsal's $WANT_CUSTODY and $WANT_RESERVE"
    echo
    echo "Between setBalanceModule(v2) and v2's switches inside this one migrate run, the Core's BALANCE exchange"
    echo "reads 0. It clears within the same run, a few blocks later, when v2's switches go on."
    dry "$P3" 18 "1,820,812 gas"
    table_ok "$DRY_LOG" 13 "migrate preview"
    yes_or_exit
    send "$P3"
  else
    resume 18 "$V1"
  fi
  [ "$(lc "$(c call "$CORE" 'controller()(address)')")" = "$(lc "$CONTROLLER_V3")" ] || stop "the Core's controller is not V3 after the migrate send"
  readback ""
  MIGRATED_NOW=1
  # the exchange paying from v2 is the one production fact the fork cannot prove: v2's available is its working
  # funds, custody less the claim reserve, since no sweep share is set (decision 295), and the Core bids BALANCE for
  # the pile head
  avail=$(c call "$TREASURY_V2" 'available()(uint256)' | word)
  head=$(c call "$CORE" 'pilePage(uint256,uint256)(uint256[])' 0 1 | tr -d '[]' | awk -F', ' '{print $1}' | word)
  bal=$(c call "$CORE" 'balanceBidOf(uint256)(uint256)' "$head" | word)
  echo
  echo "v2 available(): $(cast from-wei "$avail") BALANCE (expected about 513,044, the v1 custody less its claim reserve)"
  echo "Core balanceBidOf(credit $head): $(cast from-wei "$bal") BALANCE (expected nonzero)"
  near "$avail" "$WANT_AVAILABLE" || stop "v2 available() is $avail, not the $WANT_AVAILABLE expected"
  [ "$bal" != 0 ] || stop "the Core's balanceBidOf($head) reads 0 after the migrate: the exchange is not paying from v2"
  cat <<EOF

Keeper, by hand on Fly, before going on (this script never touches the keeper). The running keeper must be built
from main at 03d38f5 or later; Fly release v21 (2026-10-22) predates the postMarketFloor door, so it is deployed,
not only restarted. It reads the controller from the Core, so nothing is repointed. OPENSEA_API_KEY is already a
secret of cc-keeper-mainnet. Deploy it from the main checkout:

  cd $ROOT && fly deploy . --config keeper/fly.mainnet.toml --ha=false

Then watch its log. Within a few minutes it should print "collection bid observed", and postMarketFloor should not
skip with "no collection bid observed on OpenSea":

  fly logs --app cc-keeper-mainnet

Without the keeper's posts the floor this run posted goes stale after 6 hours, and the credits the floor term lifts
stop selling until a fresh post. Nothing is lost: credits priced by points keep selling, and the owner can repost
with ControllerV3 postMarketFloor as a stopgap.
EOF
else
  echo "migrate: done (the Core's controller is V3)"
fi

# --- 5 ens
WHERE=ens
res=$(c call "$ENS_REGISTRY" 'resolver(bytes32)(address)' "$VAULT_NODE")
if [ "$(lc "$(c call "$res" 'addr(bytes32)(address)' "$VAULT_NODE")")" != "$(lc "$TREASURY_V2")" ]; then
  export STEP=ens
  dry "$P3" 1 "42,052 gas"
  yes_or_exit
  send "$P3"
  [ "$(lc "$(c call "$res" 'addr(bytes32)(address)' "$VAULT_NODE")")" = "$(lc "$TREASURY_V2")" ] || stop "vault.creditcycle.eth does not resolve to v2 after the send"
fi
echo "ens: vault.creditcycle.eth resolves to v2"

# --- 6 readback. the plain readback is the state right after migrate (the floor and CC reference fresh from the run);
# once the keeper posts, those rows are its, so a later run leaves them to the LIVE=1 readback after the bid
WHERE=readback
if [ "$MIGRATED_NOW" = 1 ]; then readback ""; else echo "readback: passed right after migrate; the LIVE=1 readback follows the bid"; fi

# --- 4 bid, once the bid spender's one day activation has passed
WHERE=bid
sp=$(c call "$TREASURY_V2" "spenders(address)($SPENDER_TUPLE)" "$CREDIT_BID")
if [ "$(printf '%s' "$sp" | field 2)" != true ]; then
  at=$(printf '%s' "$sp" | field 5)
  now=$(c block latest --field timestamp)
  if [ "$now" -lt "$at" ]; then
    echo
    echo "bid: the bid spender activates at $at, $(date -u -r "$at" '+%Y-%m-%d %H:%M:%S UTC'); the chain reads $now."
    echo "Its preview refuses before then. Run the same command again after that time:"
    echo
    echo "  $RERUN"
    exit 0
  fi
  # the bid's share (unless a stopped run already set it), the sweep into its bucket, then the switch
  want=2
  [ "$(printf '%s' "$sp" | field 3)" != 10000 ] && want=3
  export STEP=bid
  dry "$P3" "$want" "183,675 gas"
  yes_or_exit
  send "$P3"
  [ "$(c call "$TREASURY_V2" "spenders(address)($SPENDER_TUPLE)" "$CREDIT_BID" | field 2)" = true ] || stop "the bid spender is not on after the send"
fi
echo "bid: the bid spender is on"
readback 1
echo
echo "Phase 3 sequence complete. Redeemer 2 stays off; switching it on is a later owner decision."
