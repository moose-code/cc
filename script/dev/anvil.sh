#!/usr/bin/env bash
# local anvil mainnet fork for the credits engine end to end.
# forks mainnet at the pin block. auto impersonation lets the deploy and the
# scenario send from the real factory owner and from the seeded accounts.
# optional state dump/load for fast restarts.
#
#   script/dev/anvil.sh                 start a fresh fork on port 8545 (live stack, chain id 31337)
#   script/dev/anvil.sh --dump-state    dump state to the gitignored path on exit
#   script/dev/anvil.sh --load-state    load state from the gitignored path at start
#   STACK=master script/dev/anvil.sh    fork, then load the master stack dump
#                                       (script/config/stack-master-26158000.hex) via anvil_loadState
set -euo pipefail

STACK="${STACK:-live}"
FORK_URL="${FORK_URL:-https://gateway.tenderly.co/public/mainnet}"
FORK_BLOCK="${FORK_BLOCK:-26158000}"
PORT="${PORT:-8545}"
STATE_FILE="${STATE_FILE:-script/dev/.anvil-state.json}"
MASTER_DUMP="${MASTER_DUMP:-script/config/stack-master-26158000.hex}"

# the local node is chain id 31337 for both stacks. the master dump is state, not a chain id (it was built on a chain
# id 1 fork, which the forge scripts re-enter with --chain-id 1 against this 31337 node). the owner's wallet and the
# web local mode key on 31337, so a chain id 1 node would make the wallet send to real mainnet.
CHAIN_ID="${CHAIN_ID:-31337}"   # 1 lets Seaport accept the signatures of live OpenSea orders

args=(
  --fork-url "$FORK_URL"
  --fork-block-number "$FORK_BLOCK"
  --chain-id "$CHAIN_ID"
  --port "$PORT"
  --auto-impersonate
  --retries 10
  --timeout 60000
)

for a in "$@"; do
  case "$a" in
    --dump-state) args+=(--dump-state "$STATE_FILE") ;;
    --load-state) args+=(--load-state "$STATE_FILE") ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

if [ "$STACK" != master ]; then
  exec anvil "${args[@]}"
fi

# master: the dump is anvil_dumpState gzip hex, loadable only through the anvil_loadState rpc, not --load-state.
[ -f "$MASTER_DUMP" ] || { echo "no master dump at $MASTER_DUMP. rebuild per docs/RUNBOOK.md section 7" >&2; exit 1; }
RPC="http://127.0.0.1:$PORT"
anvil "${args[@]}" &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
printf '{"jsonrpc":"2.0","id":1,"method":"anvil_loadState","params":["%s"]}' "$(cat "$MASTER_DUMP")" |
  curl -s -X POST "$RPC" -H 'content-type: application/json' --data @- >/dev/null
echo "master stack loaded onto chain id $CHAIN_ID at $RPC (factory 0x57bdE85D39AdE61146871029A850FC9E44EdbEd7)"
trap - EXIT
wait "$ANVIL_PID"
