#!/usr/bin/env bash
# the shell guards of `LAUNCH_ONLY=1 script/deploy.sh local` (docs/RUNBOOK.md, deferred launch). starts its own anvil fork,
# runs DEFER_LAUNCH=1, then asserts that each record-versus-chain guard stops LAUNCH_ONLY on a tampered record, that a dry
# run reports every failure, and that the untampered record launches.
#
#   PORT=8794 script/dev/test-launch-only-guards.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PORT="${PORT:-8794}"
case "$PORT" in 8545|42169|59997) echo "refusing: PORT $PORT is a shared port" >&2; exit 2 ;; esac
RPC="http://127.0.0.1:$PORT"
T="$(mktemp -d)"
ANVIL_PID=""
cleanup() { if [ -n "$ANVIL_PID" ]; then kill "$ANVIL_PID" 2>/dev/null || true; fi; rm -rf "$T"; }
trap cleanup EXIT
NFAIL=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; NFAIL=$((NFAIL + 1)); }

BLOCK="${FORK_BLOCK:-$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 20 ))}"
PORT="$PORT" FORK_BLOCK="$BLOCK" script/dev/anvil.sh >"$T/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = 31337 ] || { echo "no anvil on $RPC" >&2; exit 2; }

REC="$T/record.json"
run() { RPC_URL="$RPC" RECORD_FILE="$1" script/deploy.sh local; }

DEFER_LAUNCH=1 run "$REC" >"$T/defer.log" 2>&1 || { tail -20 "$T/defer.log" >&2; fail "DEFER_LAUNCH deploy"; exit 1; }
[ "$(jq -r .coinLive "$REC")" = false ] && [ "$(jq -r '.launchBlock // "none"' "$REC")" = none ] \
  && pass "DEFER_LAUNCH wrote coinLive false and no launchBlock" || fail "deferred record shape"
COIN="$(jq -r .coin "$REC")"
[ "$(cast code "$COIN" --rpc-url "$RPC")" = 0x ] && pass "the coin has no code after DEFER_LAUNCH" || fail "coin has code"

# expect <name> <jq filter that tampers the record> <text the refusal must contain>
expect() {
  jq "$2" "$REC" >"$T/bad.json"
  if LAUNCH_ONLY=1 run "$T/bad.json" >"$T/out.log" 2>&1; then fail "$1: LAUNCH_ONLY accepted a tampered record"
  elif grep -q "$3" "$T/out.log"; then pass "$1: refused ($3)"
  else fail "$1: refused for another reason: $(tail -1 "$T/out.log")"; fi
  [ "$(cast code "$COIN" --rpc-url "$RPC")" = 0x ] || fail "$1: the coin was launched"
}
expect "coinLive true" '.coinLive = true' "is not a deferred record"
expect "wrong controller" '.controller = "0x0000000000000000000000000000000000000001"' "controller on chain differs"
expect "wrong chain id" '.chainId = 1' "is for chain 1"
expect "wrong token deployer" '.tokenDeployer = "0x0000000000000000000000000000000000000001"' "tokenDeployer differs"

# a dry run reports every failure instead of the first
jq '.coinLive = true | .chainId = 1 | .controller = "0x0000000000000000000000000000000000000001"' "$REC" >"$T/bad.json"
DRY_RUN=1 LAUNCH_ONLY=1 run "$T/bad.json" >"$T/out.log" 2>&1
N="$(grep -c 'GUARD FAIL' "$T/out.log")"
[ "$N" -ge 3 ] && pass "DRY_RUN collected $N guard failures" || fail "DRY_RUN collected $N guard failures, want 3 or more"

# the untampered record launches
if LAUNCH_ONLY=1 run "$REC" >"$T/launch.log" 2>&1 \
  && [ "$(jq -r .coinLive "$REC")" = true ] && [ "$(jq -r .launchBlock "$REC")" -gt 0 ] \
  && [ "$(cast code "$COIN" --rpc-url "$RPC")" != 0x ]; then
  pass "the untampered record launched: coinLive true, launchBlock $(jq -r .launchBlock "$REC")"
else tail -20 "$T/launch.log" >&2; fail "the untampered record did not launch"; fi

[ "$NFAIL" = 0 ] && { echo "test-launch-only-guards: all passed"; exit 0; }
echo "test-launch-only-guards: $NFAIL failed" >&2; exit 1
