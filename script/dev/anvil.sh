#!/usr/bin/env bash
# local anvil mainnet fork for the credits engine end to end.
# forks mainnet at the pin block with chain id 31337. auto impersonation lets the
# deploy and the scenario send from the real factory owner and from the seeded
# accounts. optional state dump/load for fast restarts.
#
#   script/dev/anvil.sh                 start a fresh fork on port 8545
#   script/dev/anvil.sh --dump-state    dump state to the gitignored path on exit
#   script/dev/anvil.sh --load-state    load state from the gitignored path at start
set -euo pipefail

FORK_URL="${FORK_URL:-https://gateway.tenderly.co/public/mainnet}"
FORK_BLOCK="${FORK_BLOCK:-26158000}"
PORT="${PORT:-8545}"
STATE_FILE="${STATE_FILE:-script/dev/.anvil-state.json}"

args=(
  --fork-url "$FORK_URL"
  --fork-block-number "$FORK_BLOCK"
  --chain-id 31337
  --port "$PORT"
  --auto-impersonate
)

for a in "$@"; do
  case "$a" in
    --dump-state) args+=(--dump-state "$STATE_FILE") ;;
    --load-state) args+=(--load-state "$STATE_FILE") ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

exec anvil "${args[@]}"
