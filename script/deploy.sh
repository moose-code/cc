#!/usr/bin/env bash
# the single deploy path for every environment. `script/deploy.sh <env>` with env in local, rehearsal, mainnet. the
# environment is data: script/env/<env>.env holds values only (node kind, chain id, read rpc, launch config, deployer,
# wallet mode, verify, git guard and signoff flags). every environment runs the same guards, build, Preflight, Deploy,
# Postflight, record write and verification below.
#
#   script/deploy.sh local                       anvil fork, impersonated factory owner, writes deployments/31337.json
#   script/deploy.sh rehearsal                   mainnet launch config and guards on an anvil fork
#   DRY_RUN=1 script/deploy.sh mainnet           every guard evaluated, Preflight and the Deploy simulation, nothing sent
#   script/deploy.sh mainnet                     broadcast through the keystore, writes deployments/1.json
#
# DEFER_LAUNCH=1 script/deploy.sh <env> sends every transaction but the launch (both libraries, Core, controller, both
# adapters, the renderer, setCore, setController, both addAdapter) and runs the deferred postflight. the record carries
# the predicted coin and coinLive false. LAUNCH_ONLY=1 script/deploy.sh <env> then sends the launch alone, reading the
# Core from that record; it runs the full postflight and rewrites the record with coinLive true and launchBlock
# (docs/RUNBOOK.md, deferred launch).
# DRY_RUN=1: a failed git guard is a warning, every other failed guard is collected and the run exits 1 after the
# simulation. it needs no wallet, no broadcast rpc, no etherscan key and sends or verifies nothing.
# RESUME=state|record continues a stopped run (docs/RUNBOOK.md section 6). each needs CORE and FROM_BLOCK (the
# block the first run printed as `start block`). state computes missing transactions from the signed config and live
# chain state, including when the Core has not yet been created. it rechecks the owner delegation before continuing.
# state is script/Resume.s.sol, which sends what has no code on
# chain; record sends nothing and runs postflight, the record write and verification for a launch that has landed.
# the scripts require chain id 1 (Checks.sol), so forge runs with --chain-id 1; a local node keeps its own chain id
# and the record carries it.
# env rehearsal with REHEARSAL_DEPLOYER signs with a keystore on the anvil fork (docs/RUNBOOK.md section 6, signer drill).
# secrets: a keystore name comes from the shell. Direct use accepts a password file outside the repository;
# TERMINAL_KEYSTORE=1 prompts in the terminal instead. A private key in the environment of a keystore env is refused.
# API keys and the broadcast rpc come from the shell.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
USAGE="usage: [DRY_RUN=1] [DEFER_LAUNCH=1 | LAUNCH_ONLY=1] [RESUME=state|record CORE=0x.. FROM_BLOCK=<n>] script/deploy.sh <local|rehearsal|mainnet>"
die() { echo "deploy.sh: $*" >&2; exit 1; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

for a in "$@"; do
  low="$(printf '%s' "$a" | tr 'A-Z' 'a-z')"
  case "$low" in
    *private*key*|*mnemonic*|*seed*phrase*) die "refusing: a private key on the command line. sign with the keystore named in script/env/<env>.env" ;;
  esac
  if [[ "$a" =~ ^(0x)?[0-9a-fA-F]{64}$ ]]; then die "refusing: a 32 byte hex value on the command line. sign with the keystore named in script/env/<env>.env"; fi
done
[ "$#" -eq 1 ] || die "$USAGE"
ENV="$1"
case "$ENV" in local|rehearsal|mainnet) ;; *) die "$USAGE" ;; esac
ENV_FILE="script/env/$ENV.env"
[ -f "$ENV_FILE" ] || die "no $ENV_FILE"

DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in 0|1) ;; *) die "DRY_RUN is 0 or 1" ;; esac
RESUME="${RESUME:-}"
case "$RESUME" in ''|state|record) ;; *) die "RESUME is state or record" ;; esac
[ "$RESUME" != record ] || [ "$DRY_RUN" = 0 ] || die "RESUME=record has no transaction to preview"
DEFER_LAUNCH="${DEFER_LAUNCH:-0}"
LAUNCH_ONLY="${LAUNCH_ONLY:-0}"
case "$DEFER_LAUNCH$LAUNCH_ONLY" in 00|01|10) ;; *) die "DEFER_LAUNCH and LAUNCH_ONLY are 0 or 1 and do not combine" ;; esac
[ "$LAUNCH_ONLY" = 0 ] || [ -z "$RESUME" ] || die "LAUNCH_ONLY and RESUME do not combine: LAUNCH_ONLY reads the Core from the record"
export DEFER_LAUNCH
RATE_SUPPLIED="${PRELAUNCH_RATE+x}"
PRELAUNCH_RATE="${PRELAUNCH_RATE:-0}"
PRELAUNCH_RATE_HASH="${PRELAUNCH_RATE_HASH:-}"
[[ "$PRELAUNCH_RATE" =~ ^[0-9]+$ ]] || die "PRELAUNCH_RATE must be an unsigned wei amount per 100 points"
if [ "$PRELAUNCH_RATE" != 0 ]; then
  case "$LAUNCH_ONLY:$RESUME" in 1:*|0:state|0:record) ;; *) die "PRELAUNCH_RATE applies only to LAUNCH_ONLY or launch recovery" ;; esac
  [[ "$PRELAUNCH_RATE_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "PRELAUNCH_RATE_HASH must sign the config, opening rate and 3x cap"
elif [ -n "$PRELAUNCH_RATE_HASH" ]; then
  die "PRELAUNCH_RATE_HASH requires PRELAUNCH_RATE"
fi
if [ -n "$RATE_SUPPLIED" ]; then export PRELAUNCH_RATE; else unset PRELAUNCH_RATE; fi
if [ -n "$PRELAUNCH_RATE_HASH" ]; then export PRELAUNCH_RATE_HASH; else unset PRELAUNCH_RATE_HASH; fi

# the shell may override the read rpc, the launch config and (anvil only) the chain id of a local node
RPC_OVERRIDE="${RPC_URL:-}"
CONFIG_OVERRIDE="${LAUNCH_CONFIG:-}"
CHAIN_OVERRIDE="${CHAIN_ID:-}"
KEYSTORE_SHELL="${KEYSTORE_ACCOUNT:-}"
PASSWORD_SHELL="${PASSWORD_FILE:-}"
TERMINAL_KEYSTORE="${TERMINAL_KEYSTORE:-0}"
RECORD_SHELL="${RECORD_FILE:-}"
RECORD_RPC_SHELL="${RECORD_RPC_URL:-}"
LOCK_DIR_SHELL="${CONFIG_LOCK_DIR:-}"
REH_DEPLOYER="${REHEARSAL_DEPLOYER:-}"
REH_SKIP_GIT="${REHEARSAL_SKIP_GIT:-}"
set -a; . "$ENV_FILE"; set +a
# the keystore name and the password file path are not secrets. an env file that leaves them empty takes them from the
# shell, so a frozen checkout needs no edit
if [ -z "${KEYSTORE_ACCOUNT:-}" ]; then KEYSTORE_ACCOUNT="$KEYSTORE_SHELL"; fi
if [ -z "${PASSWORD_FILE:-}" ]; then PASSWORD_FILE="$PASSWORD_SHELL"; fi
case "$TERMINAL_KEYSTORE" in 0|1) ;; *) die "TERMINAL_KEYSTORE is 0 or 1" ;; esac
[ "$TERMINAL_KEYSTORE" = 0 ] || [ -z "$PASSWORD_FILE" ] || die "TERMINAL_KEYSTORE and PASSWORD_FILE do not combine"
# env rehearsal only: REHEARSAL_DEPLOYER=<addr> makes <addr> the owner, signer and DEPLOYER and signs with the keystore
# (script/dev/rehearse-signer.sh); REHEARSAL_SKIP_GIT=1 drops the git guards. both are refused in every other env
if [ -n "$REH_DEPLOYER$REH_SKIP_GIT" ] && [ "$ENV" != rehearsal ]; then die "REHEARSAL_DEPLOYER and REHEARSAL_SKIP_GIT apply to env rehearsal only"; fi
if [ -n "$REH_DEPLOYER" ]; then DEPLOYER="$REH_DEPLOYER"; WALLET=keystore; fi
if [ "$REH_SKIP_GIT" = 1 ]; then GIT_GUARD=0; fi
if [ -n "$RPC_OVERRIDE" ]; then RPC_URL="$RPC_OVERRIDE"; fi
if [ -n "$CONFIG_OVERRIDE" ]; then LAUNCH_CONFIG="$CONFIG_OVERRIDE"; fi
for k in NODE CHAIN_ID RPC_URL LAUNCH_CONFIG DEPLOYER WALLET VERIFY GIT_GUARD SIGNOFF; do
  [ -n "${!k:-}" ] || die "$k is empty in $ENV_FILE"
done
if [ -n "$CHAIN_OVERRIDE" ]; then
  [ "$NODE" = anvil ] || die "CHAIN_ID in the shell applies to an anvil node only"
  CHAIN_ID="$CHAIN_OVERRIDE"
fi
if [ -n "$LOCK_DIR_SHELL" ] && [ "$NODE" != anvil ]; then die "CONFIG_LOCK_DIR applies to anvil only"; fi
if [ -n "$RECORD_RPC_SHELL" ] && [ "$NODE" != anvil ]; then die "RECORD_RPC_URL applies to anvil only"; fi
if [ -n "$RECORD_RPC_SHELL" ]; then
  [[ "$RECORD_RPC_SHELL" =~ ^http://127[.]0[.]0[.]1:[0-9]+$ ]] || die "RECORD_RPC_URL must be a loopback anvil RPC with a numeric port"
fi
if [ -n "$LOCK_DIR_SHELL" ]; then
  case "$LOCK_DIR_SHELL" in "$ROOT"/*) ;; *) die "CONFIG_LOCK_DIR must be inside the repository for Forge to read it" ;; esac
fi
case "$NODE:$WALLET" in anvil:unlocked|anvil:keystore|live:keystore) ;; *) die "NODE $NODE with WALLET $WALLET is not a supported pair in $ENV_FILE" ;; esac
STACK="${STACK:-live}"
[ "$NODE" != live ] || [ "$STACK" = live ] || die "a live deploy requires STACK=live so owner delegation checks cannot be skipped"
export STACK
RECORD="${RECORD_SHELL:-${RECORD_FILE:-deployments/$CHAIN_ID.json}}"

NFAIL=0
FAILMSG=""
# a failed guard stops a real run; a dry run collects it and goes on
guard() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "deploy.sh: GUARD FAIL: $*" >&2; NFAIL=$((NFAIL + 1)); FAILMSG="$FAILMSG
  - $*"
  else die "refusing: $*"; fi
}
# git guards warn in a dry run and stop a real run
gitguard() {
  if [ "$DRY_RUN" = 1 ]; then echo "deploy.sh: WARN (git guard, stops a real run): $*" >&2; else die "refusing: $*"; fi
}
# an input that only a phase after the simulation uses: a dry run reports it, a real run needs it
late() {
  if [ "$DRY_RUN" = 1 ]; then echo "deploy.sh: WARN (the real run needs it): $*" >&2; else die "refusing: $*"; fi
}

# ---- secrets ----------------------------------------------------------------------------------------------------
if [ "$WALLET" = keystore ]; then
  for v in PRIVATE_KEY ETH_PRIVATE_KEY; do
    [ -z "${!v:-}" ] || die "refusing: $v is set in the environment. env $ENV signs with the keystore only"
  done
fi
unset PRIVATE_KEY ETH_PRIVATE_KEY ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD ETH_PASSWORD_FILE ETH_FROM

# ---- node ---------------------------------------------------------------------------------------------------------
RPC_HOST="$(printf '%s' "$RPC_URL" | sed -E 's#^[a-z]+://([^/@:]*@)?([^/:]+).*#\2#')"
if [ "$NODE" = anvil ]; then
  case "$RPC_HOST" in
    127.0.0.1|localhost) ;;
    *) die "env $ENV refuses a non local rpc: $RPC_HOST" ;;
  esac
fi
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "$CHAIN_ID" ] || die "the rpc at $RPC_HOST is not chain $CHAIN_ID"
if [ -n "$RECORD_RPC_SHELL" ]; then
  [ "$(cast chain-id --rpc-url "$RECORD_RPC_SHELL")" = "$CHAIN_ID" ] || die "RECORD_RPC_URL is not chain $CHAIN_ID"
fi

SEND_RPC="$RPC_URL"
if [ -n "${SEND_RPC_VAR:-}" ]; then
  SEND_RPC="${!SEND_RPC_VAR:-}"
  if [ -z "$SEND_RPC" ]; then
    late "$SEND_RPC_VAR is empty in the shell. the broadcast goes through that private relay"
  elif [ "$DRY_RUN" = 0 ] && [ "$(cast chain-id --rpc-url "$SEND_RPC")" != "$CHAIN_ID" ]; then
    die "the rpc in $SEND_RPC_VAR is not chain $CHAIN_ID"
  fi
fi
if [ "$VERIFY" = 1 ] && [ -z "${ETHERSCAN_API_KEY:-}" ]; then late "ETHERSCAN_API_KEY is empty in the shell"; fi

# ---- config and signer --------------------------------------------------------------------------------------------
[ -f "$LAUNCH_CONFIG" ] || die "no $LAUNCH_CONFIG. Set LAUNCH_CONFIG to the reviewed launch JSON (docs/RUNBOOK.md step 1)"
CFG_OWNER="$(jq -r .owner "$LAUNCH_CONFIG")"
FACTORY="$(jq -r .stack.factory "$LAUNCH_CONFIG")"

WALLET_FLAGS=()
SIGNER="$DEPLOYER"
if [ "$WALLET" = keystore ]; then
  if [ -z "${KEYSTORE_ACCOUNT:-}" ] || { [ "$TERMINAL_KEYSTORE" = 0 ] && [ -z "${PASSWORD_FILE:-}" ]; }; then
    guard "KEYSTORE_ACCOUNT is required, with PASSWORD_FILE or TERMINAL_KEYSTORE=1"
  elif [ "$TERMINAL_KEYSTORE" = 0 ] && [ ! -f "$PASSWORD_FILE" ]; then
    guard "PASSWORD_FILE $PASSWORD_FILE is not a file"
  else
    WALLET_FLAGS=(--account "$KEYSTORE_ACCOUNT")
    if [ "$TERMINAL_KEYSTORE" = 0 ]; then
      case "$(cd "$(dirname "$PASSWORD_FILE")" && pwd -P)" in
        "$ROOT"|"$ROOT"/*) guard "PASSWORD_FILE resolves inside the repository working tree. keep key material outside it" ;;
      esac
      WALLET_FLAGS+=(--password-file "$PASSWORD_FILE")
    fi
    if [ "$DRY_RUN" = 0 ]; then
      if [ -n "${APPROVAL_GATE:-}" ] && [ "$TERMINAL_KEYSTORE" = 1 ]; then
        [ "$APPROVAL_GATE" = "$SEND_RPC" ] || die "APPROVAL_GATE is not the transaction RPC"
        [[ "$SEND_RPC" =~ ^http://127[.]0[.]0[.]1:[0-9]+$ ]] || die "APPROVAL_GATE requires the local signed-transaction gate"
        PARENT_COMMAND="$(ps -p "$PPID" -o command=)" || die "cannot identify the deployment wrapper"
        [[ "$PARENT_COMMAND" == *script/mainnet-launch.py* ]] || die "APPROVAL_GATE is reserved for the deployment wrapper"
        GATE_OWNER="$(cast rpc cc_approvalGateOwner --rpc-url "$SEND_RPC" | tr -d '"')" \
          || die "the local approval gate did not report its expected owner"
        [ "$(lc "$GATE_OWNER")" = "$(lc "$DEPLOYER")" ] || die "the local approval gate is for another owner"
        # The wrapper checks the recovered signer of every signed transaction before forwarding it.
      else
        SIGNER="$(cast wallet address "${WALLET_FLAGS[@]}")"
      fi
    fi
  fi
else
  WALLET_FLAGS=(--unlocked)
fi
[ "$(lc "$SIGNER")" = "$(lc "$DEPLOYER")" ] || guard "the keystore signer $SIGNER is not DEPLOYER $DEPLOYER"
[ "$(lc "$DEPLOYER")" = "$(lc "$CFG_OWNER")" ] || guard "DEPLOYER $DEPLOYER is not the owner $CFG_OWNER of $LAUNCH_CONFIG"
FACTORY_OWNER="$(cast call "$FACTORY" 'owner()(address)' --rpc-url "$RPC_URL")"
[ "$(lc "$SIGNER")" = "$(lc "$FACTORY_OWNER")" ] || guard "the signer $SIGNER is not the owner $FACTORY_OWNER of the factory $FACTORY"
case "$(cast code "$DEPLOYER" --rpc-url "$RPC_URL")" in
  0xef0100*) echo "deploy.sh: $DEPLOYER carries an EIP 7702 delegation: one transaction in flight, the broadcast waits for each receipt (--slow)" ;;
esac

# STACK=master repoints local or rehearsal scripts at the master stack fork (docs/RUNBOOK.md section 7).

# LAUNCH_ONLY reads the Core and the start block from the deferred record and checks them against the chain. a dry run
# collects every failure through guard. from here on it runs as RESUME=state with the extra Resume.s.sol rows (every step
# before the launch on chain, the factory settings the deferred run saw). the build identity of the Core is enforced by
# the CREATE2 address comparison in resumeChecks (the creation code and constructor arguments are in the salt derivation
# of the address), so the shell compares addresses only
RECORD_TOKEN_DEPLOYER=""
if [ "$LAUNCH_ONLY" = 1 ]; then
  [ -f "$RECORD" ] || die "LAUNCH_ONLY needs the deferred record $RECORD (DEFER_LAUNCH=1 writes it)"
  CORE="$(jq -r .core "$RECORD")"; FROM_BLOCK="$(jq -r .deployBlock "$RECORD")"
  RECORD_TOKEN_DEPLOYER="$(jq -r '.tokenDeployer // ""' "$RECORD")"
  [ "$(jq -r .coinLive "$RECORD")" = false ] || guard "$RECORD is not a deferred record (coinLive is not false)"
  [ "$(jq -r '.launchBlock // "none"' "$RECORD")" = none ] || guard "$RECORD already has a launchBlock"
  [ "$(jq -r .chainId "$RECORD")" = "$CHAIN_ID" ] || guard "$RECORD is for chain $(jq -r .chainId "$RECORD"), not $CHAIN_ID"
  [[ "$RECORD_TOKEN_DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]] || guard "$RECORD has no tokenDeployer"
  if [ "$(cast code "$CORE" --rpc-url "$RPC_URL")" = 0x ]; then
    guard "the record Core $CORE has no code on chain"
  else
    [ "$(lc "$(cast call "$CORE" 'controller()(address)' --rpc-url "$RPC_URL")")" = "$(lc "$(jq -r .controller "$RECORD")")" ] \
      || guard "the Core controller on chain differs from the record"
    RCOIN="$(cast call "$CORE" 'COIN()(address)' --rpc-url "$RPC_URL")"
    [ "$(lc "$RCOIN")" = "$(lc "$(jq -r .coin "$RECORD")")" ] || guard "the Core coin on chain differs from the record coin"
    [ "$(cast code "$RCOIN" --rpc-url "$RPC_URL")" = 0x ] || guard "the predicted coin $RCOIN already has code"
    for k in seaportAdapter strategyAdapter; do
      [ "$(cast call "$CORE" 'allowedAdapter(address)(bool)' "$(jq -r ".$k" "$RECORD")" --rpc-url "$RPC_URL")" = true ] \
        || guard "the record $k is not an allowed adapter of the Core"
    done
  fi
  [ "$(cast call "$FACTORY" 'deprecated()(bool)' --rpc-url "$RPC_URL")" = true ] \
    || guard "the factory $FACTORY is no longer deprecated: the deferred run saw deprecated true"
  [ "$(lc "$(cast call "$FACTORY" 'tokenDeployer()(address)' --rpc-url "$RPC_URL")")" = "$(lc "$RECORD_TOKEN_DEPLOYER")" ] \
    || guard "the factory tokenDeployer differs from the record tokenDeployer $RECORD_TOKEN_DEPLOYER"
  RESUME=state
fi
export RECORD_TOKEN_DEPLOYER

if [ -n "$RESUME" ]; then
  [[ "${CORE:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "RESUME needs CORE=<the Core address of this config>"
  [[ "${FROM_BLOCK:-}" =~ ^[0-9]+$ ]] || die "RESUME needs FROM_BLOCK=<the block the first run printed as start block>"
fi
if [ "$NODE" = live ] && [ -e "$RECORD" ] && [ -z "$RESUME" ]; then
  guard "$RECORD exists. a second launch of the same config needs RESUME, or move the record away first"
fi

T="$(mktemp -d)"
TMPREC=""
trap 'rm -rf "$T"; if [ -n "$TMPREC" ]; then rm -f "$TMPREC"; fi' EXIT

# ---- build and git guards -----------------------------------------------------------------------------------------
# the build runs first: a cold build takes minutes and nothing after it depends on wall clock time
BUILD="$(forge build 2>&1)" || { echo "$BUILD" | tail -40; die "build failed"; }
echo "deploy.sh: env $ENV, build ok, rpc $RPC_HOST config $LAUNCH_CONFIG stack $STACK$([ "$DRY_RUN" = 1 ] && echo ', DRY RUN')"

# The deferred record names the exact CREATE2 libraries of this build. Compare it with the compiled creation code
# before sending LAUNCH_ONLY, so a stale or tampered record cannot silently change the verification inputs.
if [ "$LAUNCH_ONLY" = 1 ]; then
  library_address() {
    local code hash
    code="$(jq -er .bytecode.object "out/$1.sol/$1.json")" || die "no creation code for $1"
    hash="$(cast keccak "$code")"
    cast compute-address 0x4e59b44847b379578588920cA78FbF26c0B4956C \
      --salt 0x0000000000000000000000000000000000000000000000000000000000000000 --init-code-hash "$hash"
  }
  for pair in 'library CoreLib' 'opsLibrary CoreOpsLib'; do
    read -r field artifact <<<"$pair"
    expected="$(library_address "$artifact")"
    [ "$(lc "$(jq -r ".$field // \"\"" "$RECORD")")" = "$(lc "$expected")" ] \
      || guard "the record $field differs from the compiled $artifact address $expected"
  done
fi

if [ "$GIT_GUARD" = 1 ]; then
  # forge build rewrites foundry.lock and lib/solady (docs/RUNBOOK.md section 0)
  git checkout -- foundry.lock 2>/dev/null || true
  git submodule update -- lib/solady >/dev/null 2>&1 || true
  DIRTY="$(git status --porcelain)"
  if [ -n "$DIRTY" ]; then gitguard "the git tree is not clean: $(printf '%s' "$DIRTY" | head -3 | tr '\n' ';')"; fi
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != main ]; then gitguard "the branch is $BRANCH, not main"; fi
  if ! script/tools/check-freeze.sh >"$T/freeze.log" 2>&1; then
    gitguard "the freeze table is not ok: $(grep -E '^fail' "$T/freeze.log" | head -3 | tr '\n' ';')"
  fi
fi

# ---- local node setup ---------------------------------------------------------------------------------------------
if [ "$NODE" = anvil ]; then
  cast rpc anvil_setBalance "$DEPLOYER" 0x21e19e0c9bab2400000 --rpc-url "$RPC_URL" >/dev/null
fi

FLAGS=(--rpc-url "$RPC_URL" --chain-id 1 --sender "$DEPLOYER")
START="${FROM_BLOCK:-$(cast block-number --rpc-url "$RPC_URL")}"
echo "deploy.sh: start block $START, signer nonce $(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")"

# ---- preflight, signoff -------------------------------------------------------------------------------------------
echo "deploy.sh: preflight"
PRE_RC=0
PRE="$(DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" forge script script/Preflight.s.sol "${FLAGS[@]}" 2>&1)" || PRE_RC=$?
PRE_HASH="$(printf '%s\n' "$PRE" | grep -oE 'CONFIG_HASH=0x[0-9a-fA-F]{64}' | tail -1 | cut -d= -f2 || true)"
[ -n "$PRE_HASH" ] || { echo "$PRE" | tail -40; die "no CONFIG_HASH from preflight"; }
echo "deploy.sh: CONFIG_HASH=$PRE_HASH"
PRE_OK=1
CORE_ABSENT=0
if [ -n "$RESUME" ] && [ "$(cast code "$CORE" --rpc-url "$RPC_URL")" = 0x ]; then CORE_ABSENT=1; fi
if [ "$PRE_RC" != 0 ] && { [ -z "$RESUME" ] || [ "$CORE_ABSENT" = 1 ]; }; then
  PRE_OK=0
  printf '%s\n' "$PRE" | grep -E '^ +(failed: |[0-9]+ of )' | sed 's/^ */  /' || true
  guard "preflight failed: $(printf '%s\n' "$PRE" | grep -E '^ +failed: ' | sed -E 's/^ +failed: //' | head -1)"
fi
if [ -n "$RESUME" ] && [ "$CORE_ABSENT" = 0 ]; then
  OWNER_PRE="$(script/tools/check-resume-owner.sh "$PRE_RC" <<<"$PRE")" || guard "$OWNER_PRE"
fi
if [ "$SIGNOFF" = 1 ]; then
  if [ -z "${CONFIG_HASH:-}" ]; then
    late "CONFIG_HASH is not set. export the hash preflight prints for $LAUNCH_CONFIG after the sign off (docs/RUNBOOK.md step 4)"
    CONFIG_HASH="$PRE_HASH"
  elif [ "$(lc "$CONFIG_HASH")" != "$(lc "$PRE_HASH")" ]; then
    guard "CONFIG_HASH $CONFIG_HASH is not the preflight hash $PRE_HASH of $LAUNCH_CONFIG"
  fi
else
  CONFIG_HASH="$PRE_HASH"
fi
export CONFIG_HASH
LOCK_DIR="${LOCK_DIR_SHELL:-broadcast/config-locks}"
LOCK="$LOCK_DIR/${CHAIN_ID}-$(lc "$DEPLOYER").json"
BACKUP="${CONFIG_LOCK_BACKUP:-}"
if { [ "$NODE" = live ] || [ -n "$BACKUP" ]; } && { [ "$DRY_RUN" = 0 ] || [ -n "$RESUME" ] || [ "$LAUNCH_ONLY" = 1 ]; }; then
  [ -n "$BACKUP" ] || late "CONFIG_LOCK_BACKUP must name a durable path outside this repository"
  if [ -n "$BACKUP" ]; then
    case "$BACKUP" in /*) ;; *) die "CONFIG_LOCK_BACKUP must be an absolute path" ;; esac
    case "$(cd "$(dirname "$BACKUP")" && pwd -P)" in "$ROOT"|"$ROOT"/*) die "CONFIG_LOCK_BACKUP must be outside this repository" ;; esac
    if [ ! -e "$LOCK" ] && [ -f "$BACKUP" ]; then mkdir -p "$LOCK_DIR"; cp "$BACKUP" "$LOCK"; fi
  fi
fi
if [ "$DRY_RUN" = 1 ] && { [ "$LAUNCH_ONLY" = 1 ] || [ "$RESUME" = state ]; }; then
  if [ ! -f "$LOCK" ]; then PRE_OK=0; guard "no original signed config lock $LOCK";
  elif ! jq -e --arg hash "$(lc "$CONFIG_HASH")" '(.configHash | ascii_downcase) == $hash' "$LOCK" >/dev/null; then
    PRE_OK=0; guard "the deferred config lock differs from the signed config"
  fi
fi

# ---- dry run ends here --------------------------------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  if [ "$PRE_OK" = 1 ]; then
    echo "deploy.sh: deploy simulation"
    if [ "$LAUNCH_ONLY" = 1 ] || [ "$RESUME" = state ]; then SIM=script/Resume.s.sol; else SIM=script/Deploy.s.sol; fi
    if DEP="$(CORE="${CORE:-}" LAUNCH_ONLY="$LAUNCH_ONLY" RECORD_TOKEN_DEPLOYER="$RECORD_TOKEN_DEPLOYER" CONFIG_LOCK="$LOCK" CONFIG_HASH="$CONFIG_HASH" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" forge script "$SIM" "${FLAGS[@]}" 2>&1)"; then
      printf '%s\n' "$DEP" | grep -E '^ +(core|coin|coin \(predicted, launch deferred\)|controller|seaport adapter|strategy adapter|renderer) 0x' || true
      printf '%s\n' "$DEP" | grep -E '^ +gas of step [0-9]+ [0-9]+' || true
    else
      echo "$DEP" | tail -40; guard "the deploy simulation failed"
    fi
  fi
  if [ "$VERIFY" = 1 ]; then echo "deploy.sh: a real run verifies core, controller, both adapters, renderer and both libraries on etherscan after the record"; fi
  if [ "$NFAIL" -gt 0 ]; then
    echo "deploy.sh: DRY RUN: $NFAIL guard(s) would stop a real run:$FAILMSG" >&2
    exit 1
  fi
  echo "deploy.sh: DRY RUN: every guard and the simulation passed; nothing was sent"
  exit 0
fi

# ---- broadcast ----------------------------------------------------------------------------------------------------
# A recovery must use the exact config signed before the first transaction. Core's CREATE2 address does not include
# every controller, adapter and coin input, so its address alone cannot prove this. Keep this lock across interruptions.
if [ "$NODE" = live ]; then
  [ -n "$BACKUP" ] || die "CONFIG_LOCK_BACKUP must name a durable path outside this repository before a live broadcast"
fi
if [ -e "$LOCK" ]; then
  jq -e --arg chain "$CHAIN_ID" --arg owner "$(lc "$DEPLOYER")" --arg hash "$(lc "$CONFIG_HASH")" \
    '(.chainId | tostring) == $chain and (.deployer | ascii_downcase) == $owner and (.configHash | ascii_downcase) == $hash' \
    "$LOCK" >/dev/null || die "$LOCK belongs to another signed config, chain or deployer; inspect the interrupted deployment before another launch"
elif [ -n "$RESUME" ] || [ "$LAUNCH_ONLY" = 1 ]; then
  die "no $LOCK from the original deploy; state recovery needs the original signed config lock"
else
  mkdir -p "$(dirname "$LOCK")"
  (set -C; jq -n --argjson chainId "$CHAIN_ID" --arg deployer "$DEPLOYER" --arg configHash "$CONFIG_HASH" \
    '{chainId:$chainId,scriptChainId:1,deployer:$deployer,configHash:$configHash}' >"$LOCK") \
    || die "could not create $LOCK without replacing an existing lock"
fi
if [ -n "$BACKUP" ]; then
  if [ -e "$BACKUP" ]; then
    cmp -s "$LOCK" "$BACKUP" || die "the durable config lock backup differs from $LOCK"
  else
    (set -C; cat "$LOCK" >"$BACKUP") || die "could not create durable config lock backup before broadcast"
  fi
fi
if [ "$LAUNCH_ONLY" = 1 ]; then
  [ "$(lc "$(jq -r '.configHash // ""' "$RECORD")")" = "$(lc "$CONFIG_HASH")" ] \
    || die "the deferred record was signed for a different config"
fi
BFLAGS=(--rpc-url "$SEND_RPC" --chain-id 1 --sender "$DEPLOYER" ${WALLET_FLAGS[@]+"${WALLET_FLAGS[@]}"} --broadcast --slow)
# the output of a live broadcast streams to the terminal; a local one is read from the log on failure
run_script() {
  local log="$1"; shift
  if [ "$NODE" = live ]; then "$@" 2>&1 | tee "$log"; else "$@" >"$log" 2>&1; fi
}
case "$RESUME" in
  record)
    echo "deploy.sh: no transaction is sent; postflight, record and verification for the launch at $CORE"
    ;;
  state)
    echo "deploy.sh: resume from the chain"
    run_script "$T/deploy.log" env CORE="$CORE" LAUNCH_ONLY="$LAUNCH_ONLY" RECORD_TOKEN_DEPLOYER="$RECORD_TOKEN_DEPLOYER" CONFIG_LOCK="$LOCK" CONFIG_HASH="$CONFIG_HASH" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
      forge script script/Resume.s.sol "${BFLAGS[@]}" || { tail -60 "$T/deploy.log"; die "resume failed"; }
    ;;
  *)
    echo "deploy.sh: deploy"
    run_script "$T/deploy.log" env CONFIG_HASH="$CONFIG_HASH" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
      forge script script/Deploy.s.sol "${BFLAGS[@]}" || { tail -60 "$T/deploy.log"; die "deploy failed"; }
    CORE="$(grep -oE '^[[:space:]]*core 0x[0-9a-fA-F]{40}' "$T/deploy.log" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' || true)"
    [ -n "$CORE" ] || { tail -60 "$T/deploy.log"; die "could not read the Core address from the deploy output"; }
    ;;
esac

# the read rpc can trail the relay: wait for the Core and the coin
wait_code() {
  local a="$1" n=0
  until [ "$(cast code "$a" --rpc-url "$RPC_URL")" != 0x ]; do
    n=$((n + 1)); [ "$n" -lt 80 ] || die "no code at $a on the read rpc after 4 minutes"
    sleep 3
  done
}
wait_code "$CORE"
COIN="$(cast call "$CORE" 'COIN()(address)' --rpc-url "$RPC_URL")"
if [ "$DEFER_LAUNCH" = 1 ]; then
  [ "$(cast code "$COIN" --rpc-url "$RPC_URL")" = 0x ] || die "DEFER_LAUNCH: the predicted coin $COIN has code on chain"
else
  wait_code "$COIN"
fi

# ---- postflight, record -------------------------------------------------------------------------------------------
echo "deploy.sh: postflight"
POST="$(CORE="$CORE" DEPLOYER="$DEPLOYER" CONFIG_HASH="$CONFIG_HASH" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
  forge script script/Postflight.s.sol "${FLAGS[@]}" 2>&1)" || { echo "$POST" | tail -60; die "postflight failed"; }
REC="$(printf '%s\n' "$POST" | grep -E '^[[:space:]]*record: \{' | tail -1 | sed -E 's/^[[:space:]]*record: //')"
[ -n "$REC" ] || { echo "$POST" | tail -40; die "postflight printed no record line"; }

# the block of the Core creation: the first block from the start of the run with code at the Core address
lo="$START"; hi="$(cast block-number --rpc-url "$RPC_URL")"
while [ "$lo" -lt "$hi" ]; do
  mid=$(((lo + hi) / 2))
  if [ "$(cast code "$CORE" --block "$mid" --rpc-url "$RPC_URL")" != 0x ]; then hi=$mid; else lo=$((mid + 1)); fi
done
[ "$(cast code "$CORE" --block "$lo" --rpc-url "$RPC_URL")" != 0x ] || die "no code at the Core at block $lo"
if [ "$lo" -eq 0 ] || [ "$(cast code "$CORE" --block $((lo - 1)) --rpc-url "$RPC_URL")" != 0x ]; then
  die "the Core already had code before block $lo: the start block is after the creation"
fi

# the block of the launch: the first block from the Core creation with code at the coin
LAUNCH_BLOCK=""
if [ "$DEFER_LAUNCH" = 0 ]; then
  a="$lo"; b="$(cast block-number --rpc-url "$RPC_URL")"
  while [ "$a" -lt "$b" ]; do
    mid=$(((a + b) / 2))
    if [ "$(cast code "$COIN" --block "$mid" --rpc-url "$RPC_URL")" != 0x ]; then b=$mid; else a=$((mid + 1)); fi
  done
  [ "$(cast code "$COIN" --block "$a" --rpc-url "$RPC_URL")" != 0x ] || die "no code at the coin at block $a"
  LAUNCH_BLOCK="$a"
fi

# the v2 factory's token deployer: saved at the deferred run, compared again by LAUNCH_ONLY
if [ "$LAUNCH_ONLY" = 1 ]; then TOKEN_DEPLOYER="$RECORD_TOKEN_DEPLOYER"
else TOKEN_DEPLOYER="$(cast call "$FACTORY" 'tokenDeployer()(address)' --rpc-url "$RPC_URL")"; fi

# the rpc url of a live record stays out of the file (a url can carry a key)
if [ "$NODE" = anvil ]; then RECORD_RPC="${RECORD_RPC_SHELL:-$RPC_URL}"; else RECORD_RPC=""; fi
mkdir -p "$(dirname "$RECORD")"
TMPREC="$(mktemp "$(dirname "$RECORD")/.record.XXXXXX")"
printf '%s' "$REC" | jq --argjson chainId "$CHAIN_ID" --arg rpcUrl "$RECORD_RPC" --argjson deployBlock "$lo" --arg launchBlock "$LAUNCH_BLOCK" --arg tokenDeployer "$TOKEN_DEPLOYER" '. as $r | {
  chainId: $chainId, rpcUrl: (if $rpcUrl == "" then null else $rpcUrl end), deployBlock: $deployBlock,
  core: $r.core, controller: $r.controller, coin: $r.coin, seaportAdapter: $r.seaportAdapter,
  strategyAdapter: $r.strategyAdapter, renderer: $r.renderer, library: $r.library, opsLibrary: $r.opsLibrary,
  credits: $r.credits, statements: $r.statements, poolManager: $r.poolManager, hook: $r.hook,
  poolFee: $r.poolFee, tickSpacing: $r.tickSpacing,
  configHash: $r.configHash, openingRate: $r.openingRate, openingRateHash: $r.openingRateHash,
  balanceToken: null, balanceModule: null, balancePool: null, owner: $r.owner,
  coinLive: ($launchBlock != ""), tokenDeployer: $tokenDeployer
} + (if $launchBlock != "" then {launchBlock: ($launchBlock | tonumber)} else {} end)' >"$TMPREC"
# the shape web (local-env.mjs), keeper (readRecord) and indexer (ponder.config.ts, indexer/deploy.sh) read
jq -e '
  def addr: type == "string" and test("^0x[0-9a-fA-F]{40}$") and (ascii_downcase != "0x0000000000000000000000000000000000000000");
  (keys | sort) == (["balanceModule","balancePool","balanceToken","chainId","coinLive","tokenDeployer","controller","coin","core","credits","deployBlock",
    "configHash","openingRate","openingRateHash",
    "hook","library","opsLibrary","owner","poolFee","poolManager","renderer","rpcUrl","seaportAdapter","statements","strategyAdapter","tickSpacing"]
    + (if .coinLive == true then ["launchBlock"] else [] end) | sort)
  and (.coinLive | type == "boolean")
  and (if .coinLive then (.deployBlock as $d | .launchBlock | type == "number" and . >= $d) else true end)
  and (.chainId | type == "number" and . > 0)
  and (.deployBlock | type == "number" and . > 0 and . == floor)
  and ([.core, .controller, .coin, .seaportAdapter, .strategyAdapter, .renderer, .library, .opsLibrary, .credits, .statements,
        .poolManager, .hook, .owner, .tokenDeployer] | all(addr))
  and (.poolFee | type == "number") and (.tickSpacing | type == "number")
  and (.openingRate | type == "string" and test("^[0-9]+$"))
  and ([.configHash, .openingRateHash] | all(type == "string" and test("^0x[0-9a-fA-F]{64}$")))
  and (.rpcUrl == null or (.rpcUrl | type == "string"))
' "$TMPREC" >/dev/null || die "the record failed the shape check; nothing was written"
[ "$(jq -r .core "$TMPREC" | tr 'A-F' 'a-f')" = "$(lc "$CORE")" ] || die "the record Core differs from the deployed Core"
chmod 644 "$TMPREC"
mv -f "$TMPREC" "$RECORD"
TMPREC=""
echo "deploy.sh: wrote $RECORD (core $CORE, deploy block $lo)"

# ---- verification -------------------------------------------------------------------------------------------------
if [ "$VERIFY" = 1 ]; then
  carg() { printf '%s\n' "$POST" | awk -v m="$1" 'index($0, m) { getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'; }
  LIB="$(jq -r .library "$RECORD")"
  OPS="$(jq -r .opsLibrary "$RECORD")"
  LIBFLAG="src/lib/CoreLib.sol:CoreLib:$LIB"
  OPSFLAG="src/lib/CoreOpsLib.sol:CoreOpsLib:$OPS"
  NVERIFY=0
  verify() { # verify <address> <path:name> [constructor args] [CoreLib] [CoreOpsLib]
    local args=(--chain 1 --watch)
    if [ -n "${3:-}" ]; then args+=(--constructor-args "$3"); fi
    if [ -n "${4:-}" ]; then args+=(--libraries "$4"); fi
    if [ -n "${5:-}" ]; then args+=(--libraries "$5"); fi
    echo "deploy.sh: verify $2 at $1"
    forge verify-contract "$1" "$2" "${args[@]}" || { echo "deploy.sh: verification of $2 failed" >&2; NVERIFY=$((NVERIFY + 1)); }
  }
  verify "$(jq -r .core "$RECORD")" src/Core.sol:Core "$(carg 'verify: core constructor args')" "$LIBFLAG" "$OPSFLAG"
  verify "$(jq -r .controller "$RECORD")" src/ControllerV1.sol:ControllerV1 "$(carg 'verify: controller constructor args')" "$LIBFLAG" "$OPSFLAG"
  verify "$(jq -r .seaportAdapter "$RECORD")" src/adapters/SeaportBasicAdapter.sol:SeaportBasicAdapter "$(carg 'verify: seaport adapter constructor args')" "$LIBFLAG" "$OPSFLAG"
  verify "$(jq -r .strategyAdapter "$RECORD")" src/adapters/CreditStrategyAdapter.sol:CreditStrategyAdapter "" "$LIBFLAG" "$OPSFLAG"
  verify "$(jq -r .renderer "$RECORD")" src/LogoCoinRenderer.sol:LogoCoinRenderer "$(cast abi-encode 'constructor(address)' "$CFG_OWNER")" "$LIBFLAG" "$OPSFLAG"
  verify "$LIB" src/lib/CoreLib.sol:CoreLib
  verify "$OPS" src/lib/CoreOpsLib.sol:CoreOpsLib
  [ "$NVERIFY" = 0 ] || die "$NVERIFY verification(s) failed. the record is written; rerun the failed forge verify-contract commands (docs/RUNBOOK.md section 3)"
fi
echo "deploy.sh: done"
