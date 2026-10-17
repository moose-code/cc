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
# DRY_RUN=1: a failed git guard is a warning, every other failed guard is collected and the run exits 1 after the
# simulation. it needs no wallet, no broadcast rpc, no etherscan key and sends or verifies nothing.
# RESUME=replay|state|record continues a stopped run (docs/RUNBOOK.md section 6). each needs CORE and FROM_BLOCK (the
# block the first run printed as `start block`). replay is `forge script --resume --slow` of broadcast/Deploy.s.sol/1/run-latest.json
# and refuses a signer nonce outside that run's nonces; state is script/Resume.s.sol, which sends what has no code on
# chain; record sends nothing and runs postflight, the record write and verification for a launch that has landed.
# the scripts require chain id 1 (Checks.sol), so forge runs with --chain-id 1; a local node keeps its own chain id
# and the record carries it.
# secrets: the keystore and its password file are named in the env file and read by forge only. a private key on the
# command line or in the environment of a keystore env is refused. API keys and the broadcast rpc come from the shell.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
USAGE="usage: [DRY_RUN=1] [RESUME=replay|state|record CORE=0x.. FROM_BLOCK=<n>] script/deploy.sh <local|rehearsal|mainnet>"
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
case "$RESUME" in ''|replay|state|record) ;; *) die "RESUME is replay, state or record" ;; esac
[ -z "$RESUME" ] || [ "$DRY_RUN" = 0 ] || die "RESUME and DRY_RUN do not combine"

# the shell may override the read rpc, the launch config and (anvil only) the chain id of a local node
RPC_OVERRIDE="${RPC_URL:-}"
CONFIG_OVERRIDE="${LAUNCH_CONFIG:-}"
CHAIN_OVERRIDE="${CHAIN_ID:-}"
KEYSTORE_SHELL="${KEYSTORE_ACCOUNT:-}"
PASSWORD_SHELL="${PASSWORD_FILE:-}"
set -a; . "$ENV_FILE"; set +a
# the keystore name and the password file path are not secrets. an env file that leaves them empty takes them from the
# shell, so a frozen checkout needs no edit
if [ -z "${KEYSTORE_ACCOUNT:-}" ]; then KEYSTORE_ACCOUNT="$KEYSTORE_SHELL"; fi
if [ -z "${PASSWORD_FILE:-}" ]; then PASSWORD_FILE="$PASSWORD_SHELL"; fi
if [ -n "$RPC_OVERRIDE" ]; then RPC_URL="$RPC_OVERRIDE"; fi
if [ -n "$CONFIG_OVERRIDE" ]; then LAUNCH_CONFIG="$CONFIG_OVERRIDE"; fi
for k in NODE CHAIN_ID RPC_URL LAUNCH_CONFIG DEPLOYER WALLET VERIFY GIT_GUARD SIGNOFF; do
  [ -n "${!k:-}" ] || die "$k is empty in $ENV_FILE"
done
if [ -n "$CHAIN_OVERRIDE" ]; then
  [ "$NODE" = anvil ] || die "CHAIN_ID in the shell applies to an anvil node only"
  CHAIN_ID="$CHAIN_OVERRIDE"
fi
case "$NODE:$WALLET" in anvil:unlocked|live:keystore) ;; *) die "NODE $NODE with WALLET $WALLET is not a supported pair in $ENV_FILE" ;; esac
RECORD="${RECORD_FILE:-deployments/$CHAIN_ID.json}"

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
[ -f "$LAUNCH_CONFIG" ] || die "no $LAUNCH_CONFIG. docs/RUNBOOK.md step 1: cp script/config/mainnet.json script/config/local.json, then fill the launch values"
CFG_OWNER="$(jq -r .owner "$LAUNCH_CONFIG")"
FACTORY="$(jq -r .stack.factory "$LAUNCH_CONFIG")"

WALLET_FLAGS=()
SIGNER="$DEPLOYER"
if [ "$WALLET" = keystore ]; then
  if [ -z "${KEYSTORE_ACCOUNT:-}" ] || [ -z "${PASSWORD_FILE:-}" ]; then
    guard "KEYSTORE_ACCOUNT and PASSWORD_FILE are empty in $ENV_FILE and in the shell. set the foundry keystore name and a password file outside the repository"
  elif [ ! -f "$PASSWORD_FILE" ]; then
    guard "PASSWORD_FILE $PASSWORD_FILE is not a file"
  else
    case "$(cd "$(dirname "$PASSWORD_FILE")" && pwd -P)" in
      "$ROOT"|"$ROOT"/*) guard "PASSWORD_FILE resolves inside the repository working tree. keep key material outside it" ;;
    esac
    WALLET_FLAGS=(--account "$KEYSTORE_ACCOUNT" --password-file "$PASSWORD_FILE")
    if [ "$DRY_RUN" = 0 ]; then
      SIGNER="$(cast wallet address --account "$KEYSTORE_ACCOUNT" --password-file "$PASSWORD_FILE")"
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

# the stack the forge scripts read; STACK=master repoints them at the master stack fork (docs/RUNBOOK.md section 7)
STACK="${STACK:-live}"
export STACK

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
PRE_OK=1
if [ "$PRE_RC" != 0 ] && [ -z "$RESUME" ]; then
  PRE_OK=0
  printf '%s\n' "$PRE" | grep -E '^ +(failed: |[0-9]+ of )' | sed 's/^ */  /' || true
  guard "preflight failed: $(printf '%s\n' "$PRE" | grep -E '^ +failed: ' | sed -E 's/^ +failed: //' | head -1)"
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

# ---- dry run ends here --------------------------------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  if [ "$PRE_OK" = 1 ]; then
    echo "deploy.sh: deploy simulation"
    if DEP="$(DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" forge script script/Deploy.s.sol "${FLAGS[@]}" 2>&1)"; then
      printf '%s\n' "$DEP" | grep -E '^ +(core|coin|controller|seaport adapter|strategy adapter|renderer) 0x' || true
    else
      echo "$DEP" | tail -40; guard "the deploy simulation failed"
    fi
  fi
  if [ "$VERIFY" = 1 ]; then echo "deploy.sh: a real run verifies core, controller, both adapters, renderer and library on etherscan after the record"; fi
  if [ "$NFAIL" -gt 0 ]; then
    echo "deploy.sh: DRY RUN: $NFAIL guard(s) would stop a real run:$FAILMSG" >&2
    exit 1
  fi
  echo "deploy.sh: DRY RUN: every guard and the simulation passed; nothing was sent"
  exit 0
fi

# ---- broadcast ----------------------------------------------------------------------------------------------------
BFLAGS=(--rpc-url "$SEND_RPC" --chain-id 1 --sender "$DEPLOYER" ${WALLET_FLAGS[@]+"${WALLET_FLAGS[@]}"} --broadcast --slow)
# the output of a live broadcast streams to the terminal; a local one is read from the log on failure
run_script() {
  local log="$1"; shift
  if [ "$NODE" = live ]; then "$@" 2>&1 | tee "$log"; else "$@" >"$log" 2>&1; fi
}
case "$RESUME" in
  replay)
    SAVED="broadcast/Deploy.s.sol/1/run-latest.json"
    [ -f "$SAVED" ] || die "no $SAVED to replay. RESUME=state continues from the chain"
    FIRST=$((16#$(jq -r '.transactions[0].transaction.nonce' "$SAVED" | sed 's/^0x//')))
    COUNT="$(jq '.transactions | length' "$SAVED")"
    NONCE="$(cast nonce "$SIGNER" --rpc-url "$RPC_URL")"
    if [ "$NONCE" -lt "$FIRST" ] || [ "$NONCE" -gt $((FIRST + COUNT)) ]; then
      die "the signer nonce $NONCE is outside the saved run's nonces $FIRST to $((FIRST + COUNT)). the saved run no longer applies; RESUME=state continues from the chain"
    fi
    echo "deploy.sh: replay of $SAVED, signer nonce $NONCE of $FIRST..$((FIRST + COUNT))"
    if [ "$NONCE" -eq $((FIRST + COUNT)) ]; then
      echo "deploy.sh: every saved transaction has landed"
    else
      run_script "$T/deploy.log" env CONFIG_HASH="$CONFIG_HASH" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
        forge script script/Deploy.s.sol "${BFLAGS[@]}" --resume || { tail -60 "$T/deploy.log"; die "replay failed"; }
    fi
    ;;
  record)
    echo "deploy.sh: no transaction is sent; postflight, record and verification for the launch at $CORE"
    ;;
  state)
    echo "deploy.sh: resume from the chain"
    run_script "$T/deploy.log" env CORE="$CORE" CONFIG_HASH="$CONFIG_HASH" DEPLOYER="$DEPLOYER" LAUNCH_CONFIG="$LAUNCH_CONFIG" \
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
wait_code "$COIN"

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

# the rpc url of a live record stays out of the file (a url can carry a key)
if [ "$NODE" = anvil ]; then RECORD_RPC="$RPC_URL"; else RECORD_RPC=""; fi
mkdir -p "$(dirname "$RECORD")"
TMPREC="$(mktemp "$(dirname "$RECORD")/.record.XXXXXX")"
printf '%s' "$REC" | jq --argjson chainId "$CHAIN_ID" --arg rpcUrl "$RECORD_RPC" --argjson deployBlock "$lo" '. as $r | {
  chainId: $chainId, rpcUrl: (if $rpcUrl == "" then null else $rpcUrl end), deployBlock: $deployBlock,
  core: $r.core, controller: $r.controller, coin: $r.coin, seaportAdapter: $r.seaportAdapter,
  strategyAdapter: $r.strategyAdapter, renderer: $r.renderer, library: $r.library,
  credits: $r.credits, statements: $r.statements, poolManager: $r.poolManager, hook: $r.hook,
  poolFee: $r.poolFee, tickSpacing: $r.tickSpacing,
  balanceToken: null, balanceModule: null, balancePool: null, owner: $r.owner
}' >"$TMPREC"
# the shape web (local-env.mjs), keeper (readRecord) and indexer (ponder.config.ts, indexer/deploy.sh) read
jq -e '
  def addr: type == "string" and test("^0x[0-9a-fA-F]{40}$") and (ascii_downcase != "0x0000000000000000000000000000000000000000");
  (keys | sort) == (["balanceModule","balancePool","balanceToken","chainId","controller","coin","core","credits","deployBlock",
    "hook","library","owner","poolFee","poolManager","renderer","rpcUrl","seaportAdapter","statements","strategyAdapter","tickSpacing"] | sort)
  and (.chainId | type == "number" and . > 0)
  and (.deployBlock | type == "number" and . > 0 and . == floor)
  and ([.core, .controller, .coin, .seaportAdapter, .strategyAdapter, .renderer, .library, .credits, .statements,
        .poolManager, .hook, .owner] | all(addr))
  and (.poolFee | type == "number") and (.tickSpacing | type == "number")
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
  LIBFLAG="src/lib/CoreLib.sol:CoreLib:$LIB"
  NVERIFY=0
  verify() { # verify <address> <path:name> [constructor args] [libraries]
    local args=(--chain 1 --watch)
    if [ -n "${3:-}" ]; then args+=(--constructor-args "$3"); fi
    if [ -n "${4:-}" ]; then args+=(--libraries "$4"); fi
    echo "deploy.sh: verify $2 at $1"
    forge verify-contract "$1" "$2" "${args[@]}" || { echo "deploy.sh: verification of $2 failed" >&2; NVERIFY=$((NVERIFY + 1)); }
  }
  verify "$(jq -r .core "$RECORD")" src/Core.sol:Core "$(carg 'verify: core constructor args')" "$LIBFLAG"
  verify "$(jq -r .controller "$RECORD")" src/ControllerV1.sol:ControllerV1 "$(carg 'verify: controller constructor args')" "$LIBFLAG"
  verify "$(jq -r .seaportAdapter "$RECORD")" src/adapters/SeaportBasicAdapter.sol:SeaportBasicAdapter "$(carg 'verify: seaport adapter constructor args')" "$LIBFLAG"
  verify "$(jq -r .strategyAdapter "$RECORD")" src/adapters/CreditStrategyAdapter.sol:CreditStrategyAdapter "" "$LIBFLAG"
  verify "$(jq -r .renderer "$RECORD")" src/LogoCoinRenderer.sol:LogoCoinRenderer "$(cast abi-encode 'constructor(address)' "$CFG_OWNER")" "$LIBFLAG"
  verify "$LIB" src/lib/CoreLib.sol:CoreLib
  [ "$NVERIFY" = 0 ] || die "$NVERIFY verification(s) failed. the record is written; rerun the failed forge verify-contract commands (docs/RUNBOOK.md section 3)"
fi
echo "deploy.sh: done"
