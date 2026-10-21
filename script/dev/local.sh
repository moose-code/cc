#!/usr/bin/env bash
# local chain for the web app, cached. starts anvil on the fork in the background, builds the state once and saves it
# with anvil_dumpState, and loads the saved state on a later run so a second run does not refetch. the cache key is a
# hash of the mode, phase, demo flag, fork block and the contract, script, standin and live record sources, so a code
# or record change misses the cache and rebuilds. the fork source is FORK_URL from the environment (anvil.sh), always
# at the pinned block, so its reads are cached on disk by foundry and shared across worktrees.
#
# MODE=attach (default): fork mainnet at a pinned post launch block (26242107) and ATTACH to the live deployed system
#   on chain id 31337: the Core, ControllerV1, coin and the rest of deployments/1.json are read live off the fork,
#   nothing is redeployed, and anvil auto impersonates so the Core owner can send. the record deployments/31337.json
#   is deployments/1.json as chain 31337 with the local rpc, so the web, keeper and indexer read the live launch
#   (stage B) state.
#     script/dev/local.sh                     the launch state (PHASE=post): nothing deployed, the record points live
#     PHASE=phase2 script/dev/local.sh        additionally run the real stage A and B as the owner against the fork:
#                                             Phase2Deploy (policy, treasury, ControllerV2, push split) on the live
#                                             BALANCE token and its pinned codehash, then Phase2Wire STEP=module and
#                                             STEP=controller and Phase2Settings. module=treasury, controller=ControllerV2,
#                                             balanceToken=the live token, the stage B settings patch; switches stay off
#     DEMO=1 PHASE=phase2 script/dev/local.sh demo state the web can exercise beyond the launch state (treasury switches
#                                             on, working funds and a claim reserve), moved from a real BALANCE holder's
#                                             real tokens (a cheat written balance reverts EmptyInk). off by default
#     FORK_BLOCK=<n> script/dev/local.sh      override the pinned fork block
#
# MODE=deploy: the legacy fresh deploy rehearsal, NOT the live system. forks before the live Core existed and deploys a
#   brand new Core/ControllerV1/coin through script/deploy.sh, seeds and runs script/dev/Scenario.s.sol (script/dev/e2e.sh).
#   use it only to rehearse the deploy mechanics, never as the live launch state.
#     MODE=deploy script/dev/local.sh             PHASE=post (default): deploy, seed, leave anvil running
#     MODE=deploy PHASE=pre|phase2 script/dev/local.sh   other seed phases
#
#   FRESH=1 script/dev/local.sh    ignore the cache and rebuild
#   script/dev/local.sh stop       stop the anvil this script started (either mode)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# the fork source is FORK_URL from the environment (anvil.sh reads it). when unset, fall back to the archive endpoint
# in the repo .env (ALCHEMY_MAINNET_URL or MAINNET_RPC_URL): the owner's test fork endpoint, billed per call, so it is
# never printed here and anvil's startup banner is masked below. anvil.sh keeps its own public default when neither is set.
if [ -z "${FORK_URL:-}" ] && [ -f .env ]; then
  _u="$(grep -E '^(ALCHEMY_MAINNET_URL|MAINNET_RPC_URL)=' .env | head -1 | cut -d= -f2- | tr -d '"')"
  if [ -n "${_u:-}" ]; then export FORK_URL="$_u"; export MAINNET_RPC_URL="${MAINNET_RPC_URL:-$_u}"; fi
  unset _u
fi

MODE="${MODE:-attach}"
PHASE="${PHASE:-post}"
PORT="${PORT:-8545}"
RPC="http://127.0.0.1:$PORT"
# attach pins a post launch block; deploy forks before the live Core (the master fixture keeps its own block)
if [ "$MODE" = attach ]; then DEFAULT_FORK_BLOCK=26242107
elif [ "${STACK:-live}" = master ]; then DEFAULT_FORK_BLOCK=26158000
else DEFAULT_FORK_BLOCK=26208025; fi
FORK_BLOCK="${FORK_BLOCK:-$DEFAULT_FORK_BLOCK}"
CACHE_DIR="script/dev/.cache"
PID_FILE="$CACHE_DIR/anvil-$PORT.pid"                   # the anvil wrapper (a masking pipe)
ANVIL_PID_FILE="$CACHE_DIR/anvil-$PORT.listener.pid"    # the anvil process that owns PORT
LOG_FILE="$CACHE_DIR/anvil-$PORT.log"
mkdir -p "$CACHE_DIR"

# the recorded wrapper pid is the masking pipe (script/dev/anvil.sh plus the log masker); on STACK=master anvil.sh
# backgrounds the real anvil as a child and does not forward its own termination to it, so the child keeps the port.
# kill both the wrapper and the recorded listener. both pids are ones this script started (start already refuses a port
# another process holds), so no foreign process on PORT is ever signalled.
stop_anvil() {
  local pf pid
  for pf in "$ANVIL_PID_FILE" "$PID_FILE"; do
    [ -f "$pf" ] || continue
    pid="$(cat "$pf")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      echo "stopped $pid on $PORT"
    fi
    rm -f "$pf"
  done
}

if [ "${1:-}" = "stop" ]; then stop_anvil; exit 0; fi

case "$MODE" in attach|deploy) ;; *) echo "MODE must be attach or deploy, got $MODE" >&2; exit 2 ;; esac
if [ "$MODE" = attach ]; then
  case "$PHASE" in post|phase2) ;; *) echo "attach PHASE must be post or phase2, got $PHASE" >&2; exit 2 ;; esac
fi

# content hash of every source the state depends on; commits and stashes leave it unchanged. a plain find (no git) so
# the script needs no repo; the cache dir, python bytecode and editor noise are excluded, local.sh excludes itself
KEY="$({
  echo "$MODE $PHASE $FORK_BLOCK ${DEMO:-0}"
  find src script test/standins test/utils foundry.toml remappings.txt deployments/1.json -type f \
    ! -path '*/.cache/*' ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '.DS_Store' ! -name 'local.sh' 2>/dev/null \
    | sort | while read -r f; do shasum "$f"; done
} | shasum | cut -c1-12)"
TAG="$MODE-$PHASE${DEMO:+-demo}"
STATE="$CACHE_DIR/state-$TAG-$KEY.hex"
RECORD="$CACHE_DIR/record-$TAG-$KEY.json"

stop_anvil
if lsof -ti "tcp:$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is in use by a process this script did not start; stop it or set PORT" >&2
  exit 1
fi

# start anvil, masking any api key in the fork endpoint out of the on disk log (the Alchemy archive url is billed and
# secret; anvil prints it in its startup banner). FORK_URL and the pin come from the environment / anvil.sh defaults.
PORT="$PORT" FORK_BLOCK="$FORK_BLOCK" nohup bash -c \
  'script/dev/anvil.sh 2>&1 | sed -E "s#(/v2/)[^[:space:]]+#\1<masked>#g"' > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
disown
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "31337" ] || { echo "anvil did not start, see $LOG_FILE" >&2; exit 1; }
# record the anvil that owns PORT now that it is up; on STACK=master this is anvil.sh's child, not the recorded pid
lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null | head -1 > "$ANVIL_PID_FILE" || true

# ----------------------------------------------------------------------------------------------------------------------
# build the attach state: write the record from the live record, and for PHASE=phase2 run the real stage A and B scripts
# ----------------------------------------------------------------------------------------------------------------------
build_attach() {
  local LIVE=deployments/1.json
  [ -f "$LIVE" ] || { echo "no $LIVE (the live record to attach to)" >&2; exit 1; }
  local CORE OWNER BALANCE_TOKEN BALANCE_TOKEN_CODEHASH DEV_WALLET FUND
  CORE="$(jq -r .core "$LIVE")"
  OWNER="$(jq -r .owner "$LIVE")"
  BALANCE_TOKEN=0x3620540c994433D7B4a628C46d2ED5F92572eA07
  BALANCE_TOKEN_CODEHASH=0x83c6085628758fb522e28b5abb7c24253b6d8667a8b2b23d2c3542deabc25de7
  DEV_WALLET="$(jq -r '.dev.wallet // .owner' script/config/anvil.json)"   # the owner's browser wallet
  FUND=0x152d02c7e14af6800000   # 100000 ether
  cast rpc anvil_setBalance "$OWNER" "$FUND" --rpc-url "$RPC" >/dev/null   # gas for impersonated owner sends

  # the record: the live record as chain 31337 with the local rpc and a web usable accounts map. balanceToken,
  # balanceModule and balancePool stay null (phase 2 is not on mainnet yet); PHASE=phase2 patches them below.
  local A1=0x1111111111111111111111111111111111111111 A2=0x2222222222222222222222222222222222222222 \
        A3=0x3333333333333333333333333333333333333333 KEEPER=0x4444444444444444444444444444444444444444 \
        TRADER=0x5555555555555555555555555555555555555555 tmp
  mkdir -p deployments
  tmp="$(mktemp)"
  jq --arg u "$RPC" --arg o "$DEV_WALLET" --arg a1 "$A1" --arg a2 "$A2" --arg a3 "$A3" --arg k "$KEEPER" --arg t "$TRADER" \
    '.chainId = 31337 | .rpcUrl = $u | .accounts = {a1: $a1, a2: $a2, a3: $a3, keeper: $k, trader: $t, owner: $o}' \
    "$LIVE" > "$tmp" && mv "$tmp" deployments/31337.json
  echo "attach: wrote deployments/31337.json from $LIVE (core $CORE, fork block $FORK_BLOCK, launch state)"
  [ "$PHASE" = "phase2" ] || return 0

  export CORE BALANCE_TOKEN BALANCE_TOKEN_CODEHASH
  local PRE PLAN OUT REC POLICY TREASURY V2 SPLIT STEP HOLDER HBAL WORK CLAIMS
  fs() { forge script "$@" --rpc-url "$RPC"; }   # a plain preview run
  grabhash() { printf '%s\n' "$1" | awk -F'\\|' '/'"$2"' of a send/{print $2}' | grep -oE '0x[0-9a-fA-F]{64}' | tail -1; }

  echo; echo "=== phase2 stage A: Phase2Deploy (policy, treasury, ControllerV2, push split) ==="
  PRE="$(fs script/Phase2Deploy.s.sol 2>&1)" || { echo "$PRE" | tail -40; echo "phase2 deploy preview failed" >&2; exit 1; }
  PLAN="$(grabhash "$PRE" PHASE2_PLAN_HASH)"
  [ -n "$PLAN" ] || { echo "$PRE" | tail -40; echo "no plan hash from the deploy preview" >&2; exit 1; }
  OUT="$(SEND=1 PHASE2_PLAN_HASH="$PLAN" fs script/Phase2Deploy.s.sol --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
    || { echo "$OUT" | tail -60; echo "phase2 deploy send failed" >&2; exit 1; }
  REC="$(printf '%s\n' "$OUT" | grep -oE 'record: \{.*\}' | tail -1 | sed 's/^record: //')"
  POLICY="$(jq -r .policy <<<"$REC")"; TREASURY="$(jq -r .treasury <<<"$REC")"; V2="$(jq -r .controllerV2 <<<"$REC")"
  SPLIT="$(printf '%s\n' "$OUT" | grep -oE 'SPLIT_ADDRESS=0x[0-9a-fA-F]{40}' | tail -1 | cut -d= -f2)"
  [ -n "$TREASURY" ] && [ -n "$V2" ] && [ -n "$POLICY" ] && [ -n "$SPLIT" ] \
    || { echo "$OUT" | tail -60; echo "could not read the phase2 addresses from the deploy send" >&2; exit 1; }
  echo "phase2 deploy: policy $POLICY treasury $TREASURY controllerV2 $V2 split $SPLIT"

  export TREASURY CONTROLLER_V2="$V2"
  for STEP in module controller; do
    echo; echo "=== phase2 stage B: Phase2Wire STEP=$STEP ==="
    export STEP
    PRE="$(fs script/Phase2Wire.s.sol 2>&1)" || { echo "$PRE" | tail -40; echo "wire $STEP preview failed" >&2; exit 1; }
    PLAN="$(grabhash "$PRE" PHASE2_WIRE_PLAN_HASH)"
    [ -n "$PLAN" ] || { echo "$PRE" | tail -40; echo "no plan hash from the wire $STEP preview" >&2; exit 1; }
    OUT="$(SEND=1 PHASE2_WIRE_PLAN_HASH="$PLAN" fs script/Phase2Wire.s.sol --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
      || { echo "$OUT" | tail -60; echo "wire $STEP send failed" >&2; exit 1; }
    echo "phase2 wire $STEP: $(printf '%s\n' "$OUT" | grep -oE 'record: \{.*\}' | tail -1)"
  done
  unset STEP

  echo; echo "=== phase2 stage B: Phase2Settings (balanceDiscountBps 2000, the split's royalty route) ==="
  OUT="$(PHASE2_ARTIST="$SPLIT" SEND=1 fs script/Phase2Settings.s.sol --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
    || { echo "$OUT" | tail -60; echo "phase2 settings send failed" >&2; exit 1; }
  printf '%s\n' "$OUT" | grep -E "^\* |^kept |^margin |^artist " || true

  # patch the record: ControllerV1 kept, controller now ControllerV2, the treasury the module, the live token bound
  tmp="$(mktemp)"
  jq --arg c "$V2" --arg t "$BALANCE_TOKEN" --arg m "$TREASURY" --arg p "$POLICY" --arg s "$SPLIT" \
    '.controllerV1 = .controller | .controller = $c | .controllerV2 = $c | .balanceToken = $t | .balanceModule = $m | .redemptionPolicy = $p | .split = $s' \
    deployments/31337.json > "$tmp" && mv "$tmp" deployments/31337.json
  echo "phase2: patched deployments/31337.json (controller $V2, balanceModule $TREASURY, balanceToken $BALANCE_TOKEN)"
  [ "${DEMO:-0}" = "1" ] || return 0

  echo; echo "=== DEMO: switches on, working funds and a claim reserve from a real holder (beyond the launch state) ==="
  export STEP=launch   # turn the treasury switches on through the real STEP=launch send
  PRE="$(fs script/Phase2Wire.s.sol 2>&1)" || { echo "$PRE" | tail -40; echo "wire launch preview failed" >&2; exit 1; }
  PLAN="$(grabhash "$PRE" PHASE2_WIRE_PLAN_HASH)"
  OUT="$(SEND=1 PHASE2_WIRE_PLAN_HASH="$PLAN" fs script/Phase2Wire.s.sol --broadcast --slow --unlocked --sender "$OWNER" 2>&1)" \
    || { echo "$OUT" | tail -60; echo "wire launch send failed" >&2; exit 1; }
  unset STEP
  echo "DEMO: treasury switches conversion+workingPayments on, CC redemption off"
  # move real BALANCE from a real holder into the treasury (working funds). a cheat written balance reverts EmptyInk, so
  # this is a real token transfer, impersonated. LIVE_BALANCE_HOLDER overrides the default auction withdrawer.
  HOLDER="${LIVE_BALANCE_HOLDER:-0x5F7a8fb8cc29e795ba19191Dd74D69A90cDADB88}"
  cast rpc anvil_setBalance "$HOLDER" "$FUND" --rpc-url "$RPC" >/dev/null   # gas for the holder
  HBAL="$(cast call "$BALANCE_TOKEN" 'balanceOf(address)(uint256)' "$HOLDER" --rpc-url "$RPC" | awk '{print $1}')"
  WORK="$(python3 -c "import sys;h=int(sys.argv[1]);w=int(sys.argv[2] or h);print(min(w,h))" "$HBAL" "${PHASE2_WORKING:-}")"
  [ "$WORK" -gt 0 ] || { echo "the holder $HOLDER has no BALANCE at block $FORK_BLOCK; set LIVE_BALANCE_HOLDER" >&2; exit 1; }
  cast send "$BALANCE_TOKEN" 'transfer(address,uint256)' "$TREASURY" "$WORK" --from "$HOLDER" --unlocked --rpc-url "$RPC" >/dev/null
  CLAIMS="$(python3 -c "import sys;w=int(sys.argv[1]);c=sys.argv[2];print(min(int(c),w) if c else w//5)" "$WORK" "${PHASE2_CLAIMS:-}")"
  [ "$CLAIMS" -gt 0 ] && cast send "$TREASURY" 'allocateToClaims(uint256)' "$CLAIMS" --from "$OWNER" --unlocked --rpc-url "$RPC" >/dev/null
  echo "DEMO: working funds $(cast call "$TREASURY" 'working()(uint256)' --rpc-url "$RPC" | awk '{print $1}'), claimReserve $(cast call "$TREASURY" 'claimReserve()(uint256)' --rpc-url "$RPC" | awk '{print $1}') (base units)"
}

if [ "${FRESH:-0}" != "1" ] && [ -f "$STATE" ] && [ -f "$RECORD" ]; then
  echo "cache hit: $TAG key $KEY"
  printf '{"jsonrpc":"2.0","id":1,"method":"anvil_loadState","params":["%s"]}' "$(cat "$STATE")" \
    | curl -sf -X POST -H 'content-type: application/json' --data-binary @- "$RPC" >/dev/null
  mkdir -p deployments
  jq --arg u "$RPC" '.rpcUrl = $u' "$RECORD" > deployments/31337.json
else
  echo "cache miss: $TAG key $KEY, building the state once"
  if [ "$MODE" = attach ]; then
    build_attach
  else
    NO_ANVIL=1 E2E_RPC_URL="$RPC" PHASE="$PHASE" script/dev/e2e.sh
  fi
  cast rpc anvil_dumpState --rpc-url "$RPC" | tr -d '"' > "$STATE"
  cp deployments/31337.json "$RECORD"
  echo "saved $STATE"
fi

if [ "$MODE" = attach ]; then
  echo "anvil running on $RPC (pid $(cat "$PID_FILE")), MODE=attach PHASE=$PHASE${DEMO:+ DEMO=1}, record deployments/31337.json"
else
  echo "anvil running on $RPC (pid $(cat "$PID_FILE")), MODE=deploy phase $PHASE (fresh deploy rehearsal, not the live system), record deployments/31337.json"
fi
echo "stop: script/dev/local.sh stop"
