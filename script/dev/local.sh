#!/usr/bin/env bash
# local chain for the web app, cached. starts anvil on the fork in the background and loads the saved state of the
# last end to end run for this phase. the cache key is a hash of the contract, script and stand in sources, the fork
# block and the phase, so a code change misses the cache and reruns script/dev/e2e.sh once, then saves.
#
#   script/dev/local.sh            PHASE=post (default): load or build, leave anvil running
#   PHASE=pre script/dev/local.sh  the engine before the balance token
#   PHASE=phase2 script/dev/local.sh  the phase 2 stack on the standin balance token, every switch on (the web's
#                                  /exchange sells Credits and burns CC locally)
#   BID=1 PHASE=phase2 script/dev/local.sh  the phase 2 stack with the standing bid installed and budgeted (its own
#                                  cache entry)
#   FRESH=1 script/dev/local.sh    ignore the cache and rebuild
#   script/dev/local.sh stop       stop the anvil this script started
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PHASE="${PHASE:-post}"
BID="${BID:-0}"
export BID
PORT="${PORT:-8545}"
RPC="http://127.0.0.1:$PORT"
if [ "${STACK:-live}" = master ]; then DEFAULT_FORK_BLOCK=26158000; else DEFAULT_FORK_BLOCK=26208025; fi
FORK_BLOCK="${FORK_BLOCK:-$DEFAULT_FORK_BLOCK}"
CACHE_DIR="script/dev/.cache"
PID_FILE="$CACHE_DIR/anvil-$PORT.pid"                   # the script/dev/anvil.sh wrapper
ANVIL_PID_FILE="$CACHE_DIR/anvil-$PORT.listener.pid"    # the anvil process that owns PORT
LOG_FILE="$CACHE_DIR/anvil-$PORT.log"
mkdir -p "$CACHE_DIR"

# the recorded wrapper pid is script/dev/anvil.sh, which on STACK=master backgrounds the real anvil as a child and does
# not forward its own termination to it, so the child keeps the port. kill both the wrapper and the recorded listener.
# both pids are ones this script started (start already refuses a port another process holds), so no foreign process on
# PORT is ever signalled.
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

# content hash of every non ignored source the run depends on; commits and stashes leave it unchanged
KEY="$({
  echo "$PHASE $FORK_BLOCK $BID"
  git ls-files -co --exclude-standard src script test/standins test/utils foundry.toml remappings.txt \
    | grep -v '^script/dev/local.sh$' | sort | while read -r f; do [ -f "$f" ] && shasum "$f"; done
} | shasum | cut -c1-12)"
TAG="$PHASE"; [ "$BID" != 1 ] || TAG="$PHASE-bid"
STATE="$CACHE_DIR/state-$TAG-$KEY.hex"
RECORD="$CACHE_DIR/record-$TAG-$KEY.json"

stop_anvil
if lsof -ti "tcp:$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is in use by a process this script did not start; stop it or set PORT" >&2
  exit 1
fi

PORT="$PORT" FORK_BLOCK="$FORK_BLOCK" nohup script/dev/anvil.sh > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
disown
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "31337" ] || { echo "anvil did not start, see $LOG_FILE" >&2; exit 1; }
# record the anvil that owns PORT now that it is up; on STACK=master this is the wrapper's child, not the recorded pid
lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null | head -1 > "$ANVIL_PID_FILE" || true

if [ "${FRESH:-0}" != "1" ] && [ -f "$STATE" ] && [ -f "$RECORD" ]; then
  echo "cache hit: phase $TAG key $KEY"
  printf '{"jsonrpc":"2.0","id":1,"method":"anvil_loadState","params":["%s"]}' "$(cat "$STATE")" \
    | curl -sf -X POST -H 'content-type: application/json' --data-binary @- "$RPC" >/dev/null
  mkdir -p deployments
  jq --arg u "$RPC" '.rpcUrl = $u' "$RECORD" > deployments/31337.json
else
  echo "cache miss: phase $TAG key $KEY, running the end to end once"
  NO_ANVIL=1 E2E_RPC_URL="$RPC" PHASE="$PHASE" BID="$BID" script/dev/e2e.sh
  cast rpc anvil_dumpState --rpc-url "$RPC" | tr -d '"' > "$STATE"
  cp deployments/31337.json "$RECORD"
  echo "saved $STATE"
fi

echo "anvil running on $RPC (pid $(cat "$PID_FILE")), phase $TAG, record deployments/31337.json"
echo "stop: script/dev/local.sh stop"
