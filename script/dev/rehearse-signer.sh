#!/usr/bin/env bash
# signer drill: `script/deploy.sh rehearsal` signing with a foundry keystore on a chain id 1 anvil fork, no unlocked
# accounts, then the RESUME=state drill. unattended, 4 phases:
#   1  full run: build, preflight, Deploy through the keystore with --slow, postflight, record
#   2  fresh state, wrapper killed after the first library transaction, state recovery sends missing steps
#   3  fresh state, wrapper killed after Core creation, state recovery sends missing steps
#   4  fresh state, killed after Core creation, an unrelated nonce advances, state recovery still uses live state
# the signer is an existing rehearsal keystore supplied by the operator. it becomes the v2 factory owner (the only impersonated send is the
# transferOwnership by the real owner, accepted by the keystore during setup), the launch config owner and creator, and carries the EIP 7702
# delegation code of the real owner, so every owner row of preflight holds. REHEARSAL_DEPLOYER (script/deploy.sh)
# points the rehearsal env at it. the only rpc used is the anvil on PORT; the fork source is read only.
#
#   script/dev/rehearse-signer.sh            PORT=8618, FORK_URL=https://gateway.tenderly.co/public/mainnet
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd -P)"
PORT="${PORT:-8618}"
FORK_URL="${FORK_URL:-https://gateway.tenderly.co/public/mainnet}"
RPC="http://127.0.0.1:$PORT"
REAL_OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
DELEGATION=0xef0100612373d7003d694220f7800eeaf8e3924c0951d3
BASE_CONFIG=script/config/mainnet.json
CONFIG=script/config/rehearse-signer.local.json   # gitignored; forge reads files under the repository only
die() { echo "rehearse-signer: $*" >&2; exit 1; }
[ "$PORT" = 8618 ] || [ -n "${ALLOW_PORT:-}" ] || die "PORT is 8618 (ALLOW_PORT=1 to change)"
lsof -ti "tcp:$PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "port $PORT is in use"

T="$(mktemp -d)"
case "$T" in "$ROOT"/*) die "temp directory inside the repository" ;; esac
ORIGINAL_BROADCAST=""
KS_NAME="${REHEARSAL_KEYSTORE_ACCOUNT:-}"
PASS_FILE="${REHEARSAL_PASSWORD_FILE:-}"
[ -n "$KS_NAME" ] && [ -f "$PASS_FILE" ] || die "set REHEARSAL_KEYSTORE_ACCOUNT and REHEARSAL_PASSWORD_FILE to an existing test keystore and password file"
case "$(cd "$(dirname "$PASS_FILE")" && pwd -P)" in "$ROOT"|"$ROOT"/*) die "password file must stay outside the repository" ;; esac
ANVIL_PID=""
cleanup() {
  if [ -n "$ANVIL_PID" ]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
  if [ -n "$ORIGINAL_BROADCAST" ]; then
    [ ! -e broadcast/Deploy.s.sol/1 ] || mv broadcast/Deploy.s.sol/1 "broadcast/Deploy.s.sol/1.rehearsal-$$"
    mv "$ORIGINAL_BROADCAST" broadcast/Deploy.s.sol/1
  fi
  rm -f "$ROOT/$CONFIG"; rm -rf "$T"
}
trap cleanup EXIT
if [ -e broadcast/Deploy.s.sol/1 ]; then
  ORIGINAL_BROADCAST="$T/original-deploy-broadcast"
  mv broadcast/Deploy.s.sol/1 "$ORIGINAL_BROADCAST"
fi

SIGNER="$(cast wallet address --account "$KS_NAME" --password-file "$PASS_FILE")"
[ -n "$SIGNER" ] || die "no keystore address"
echo "rehearse-signer: rehearsal signer $SIGNER (keystore $KS_NAME)"

FORK_BLOCK="${FORK_BLOCK:-26208025}"
if [ "$FORK_BLOCK" = head ]; then
  latest_block="$(cast block-number --rpc-url "$FORK_URL")"
  FORK_BLOCK=$((latest_block - 100))
fi
[[ "$FORK_BLOCK" =~ ^[0-9]+$ ]] || die "FORK_BLOCK must be a block number or head"
anvil --fork-url "$FORK_URL" --fork-block-number "$FORK_BLOCK" --chain-id 1 --port "$PORT" --retries 10 --timeout 60000 >"$T/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = 1 ] || die "anvil did not start: $(tail -5 "$T/anvil.log")"
rpc() { cast rpc "$@" --rpc-url "$RPC" >/dev/null; }

# ---- setup: the signer takes the owner's place on the fork ------------------------------------------------------
FACTORY="$(jq -r .stack.factory "$BASE_CONFIG")"
jq --arg s "$SIGNER" '.owner = $s | .creator = $s' "$BASE_CONFIG" >"$CONFIG"
rpc anvil_setBalance "$SIGNER" 0x21e19e0c9bab2400000
rpc anvil_setCode "$SIGNER" "$DELEGATION"
rpc anvil_setBalance "$REAL_OWNER" 0x21e19e0c9bab2400000
rpc anvil_impersonateAccount "$REAL_OWNER"
cast send "$FACTORY" 'transferOwnership(address)' "$SIGNER" --from "$REAL_OWNER" --unlocked --rpc-url "$RPC" >/dev/null
rpc anvil_stopImpersonatingAccount "$REAL_OWNER"
cast send "$FACTORY" 'acceptOwnership()' --account "$KS_NAME" --password-file "$PASS_FILE" --rpc-url "$RPC" >/dev/null
[ "$(cast call "$FACTORY" 'owner()(address)' --rpc-url "$RPC")" = "$(cast to-check-sum-address "$SIGNER")" ] || die "factory owner is not the signer"
echo "rehearse-signer: fork block $FORK_BLOCK, factory owner is the signer, signer code $(cast code "$SIGNER" --rpc-url "$RPC" | head -c 12)"

export REHEARSAL_DEPLOYER="$SIGNER" REHEARSAL_SKIP_GIT=1 RPC_URL="$RPC" CHAIN_ID=1 LAUNCH_CONFIG="$CONFIG"
export KEYSTORE_ACCOUNT="$KS_NAME" PASSWORD_FILE="$PASS_FILE" RECORD_FILE="$T/record.json" CONFIG_LOCK_DIR="$ROOT/broadcast/config-locks/rehearsal-$$"
unset PRIVATE_KEY ETH_PRIVATE_KEY

PRE="$(DEPLOYER="$SIGNER" forge script script/Preflight.s.sol --rpc-url "$RPC" --chain-id 1 --sender "$SIGNER" 2>&1)" || true
CONFIG_HASH="$(printf '%s\n' "$PRE" | grep -oE 'CONFIG_HASH=0x[0-9a-fA-F]{64}' | tail -1 | cut -d= -f2 || true)"
[ -n "$CONFIG_HASH" ] || { echo "$PRE" | tail -30; die "no CONFIG_HASH"; }
export CONFIG_HASH
SNAP="$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')"
fresh() { rpc evm_revert "$SNAP"; SNAP="$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')"; rm -rf broadcast/Deploy.s.sol/1 "$RECORD_FILE"; }
gas_table() { jq -r '[.receipts[] | (.gasUsed | if type=="string" then (.[2:] | if length>0 then "0x"+. else "0x0" end) else . end)] | join(" ")' broadcast/Deploy.s.sol/1/run-latest.json; }

# ---- phase 1: full run ------------------------------------------------------------------------------------------
fresh
echo "rehearse-signer: PHASE 1 full run"
S1=$SECONDS
script/deploy.sh rehearsal >"$T/run1.log" 2>&1 || { tail -40 "$T/run1.log"; die "phase 1 failed"; }
W1=$((SECONDS - S1))
cp "$RECORD_FILE" "$T/record1.json"
echo "rehearse-signer: phase 1 ok in ${W1}s; gas per tx (hex): $(gas_table)"
jq -r 'to_entries[] | select(.key|test("core|coin|controller|renderer|[lL]ibrary|seaport|strategy|deployBlock")) | "  \(.key) \(.value)"' "$T/record1.json"
grep -E 'ef0100|nonce' "$T/run1.log" | head -3 || true
CORE="$(jq -r .core "$T/record1.json")"

# kill the wrapper's forge once the chosen number of transactions has landed
kill_after_count() {
  local log="$1" count="$2" n0 n
  n0="$(cast nonce "$SIGNER" --rpc-url "$RPC")"
  script/deploy.sh rehearsal >"$log" 2>&1 &
  local wp=$!
  while :; do
    n="$(cast nonce "$SIGNER" --rpc-url "$RPC")"
    if [ "$n" -ge $((n0 + count)) ]; then
      pkill -9 -P "$wp" || true   # children of this wrapper run only
      kill -9 "$wp" 2>/dev/null || true
      break
    fi
    kill -0 "$wp" 2>/dev/null || die "wrapper ended before $count transactions landed"
    sleep 0.1
  done
  wait "$wp" 2>/dev/null || true
  echo "$n0"
}

drill_state() {
  fresh
  N0="$(kill_after_count "$T/$1.log" "$2" | tail -1)"
  STARTBLK="$(grep -oE 'start block [0-9]+' "$T/$1.log" | head -1 | grep -oE '[0-9]+')"
  LANDED=$(($(cast nonce "$SIGNER" --rpc-url "$RPC") - N0))
  echo "rehearse-signer: killed with $LANDED transactions landed, start block $STARTBLK"
}

# ---- phase 2: state recovery before Core ------------------------------------------------------------------------
echo "rehearse-signer: PHASE 2 recovery after first library"
drill_state kill2 1
S2=$SECONDS
RESUME=state CORE="$CORE" FROM_BLOCK="$STARTBLK" script/deploy.sh rehearsal >"$T/resume.log" 2>&1 || { tail -40 "$T/resume.log"; die "resume failed"; }
W2=$((SECONDS - S2))
jq 'del(.deployBlock)' "$T/record1.json" >"$T/a.json"; jq 'del(.deployBlock)' "$RECORD_FILE" >"$T/b.json"
cmp -s "$T/a.json" "$T/b.json" || { diff "$T/a.json" "$T/b.json" || true; die "resumed record differs from the full run record"; }
echo "rehearse-signer: phase 2 ok in ${W2}s, record matches"

# ---- phase 3: state recovery after Core -------------------------------------------------------------------------
echo "rehearse-signer: PHASE 3 recovery after Core"
drill_state kill3 3
RESUME=state CORE="$CORE" FROM_BLOCK="$STARTBLK" script/deploy.sh rehearsal >"$T/resume3.log" 2>&1 || { tail -40 "$T/resume3.log"; die "phase 3 failed"; }
jq 'del(.deployBlock)' "$RECORD_FILE" >"$T/b.json"
cmp -s "$T/a.json" "$T/b.json" || die "phase 3 record differs from the full run"

# ---- phase 4: moved nonce ---------------------------------------------------------------------------------------
echo "rehearse-signer: PHASE 4 recovery after unrelated signer transaction"
drill_state kill4 3
cast send "$SIGNER" --value 0 --account "$KS_NAME" --password-file "$PASS_FILE" --rpc-url "$RPC" >/dev/null
RESUME=state CORE="$CORE" FROM_BLOCK="$STARTBLK" script/deploy.sh rehearsal >"$T/resume4.log" 2>&1 || { tail -40 "$T/resume4.log"; die "phase 4 failed"; }
jq 'del(.deployBlock)' "$RECORD_FILE" >"$T/b.json"
cmp -s "$T/a.json" "$T/b.json" || die "phase 4 record differs from the full run"
echo "rehearse-signer: phases 3 and 4 recovered the same record"
echo "rehearse-signer: done. existing keystore and password file are preserved; the anvil is stopped on exit"
