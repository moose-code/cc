#!/usr/bin/env bash
# runs `forge script script/Preflight.s.sol` on a fork of the pin block, the way docs/DEPLOY.md step 4 runs it, and
# compares the failed rows with the expected ones. a script only failure (a cheatcode that is refused in a script
# context, a revert outside the rows) leaves the table unprinted and fails here. tests call the checks through a test
# contract and cannot see that class of failure.
# it also checks what forge cannot (ffi is off): the git tree is clean and HEAD contains the frozen candidate recorded
# in project/director-state.json (docs/DEPLOY.md step 4). the build pins are preflight rows (script/Checks.sol).
# usage: script/tools/check-preflight.sh [config.json]
# env:   MAINNET_RPC_URL (default: the Tenderly public gateway, archive state), FORK_BLOCK (default 26158000),
#        DEPLOYER (default: the config owner), EXPECT_FAIL (comma separated failed rows; default: the three rows that fail
#        on the pin block before the factory owner step: the deployer balance and the two factory rows of DEPLOY step 3)
set -euo pipefail
cd "$(dirname "$0")/../.."
cfg="${1:-script/config/mainnet.json}"
candidate="$(jq -r .candidate project/director-state.json)"
dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then echo "git tree is not clean:"; head -10 <<<"$dirty"; exit 1; fi
if ! git merge-base --is-ancestor "$candidate" HEAD; then
  echo "HEAD $(git rev-parse --short HEAD) does not contain the frozen candidate ${candidate:0:7}"; exit 1
fi
echo "ok: git tree clean, HEAD $(git rev-parse --short HEAD) contains the frozen candidate ${candidate:0:7}"
rpc="${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}"
block="${FORK_BLOCK:-26158000}"
deployer="${DEPLOYER:-$(jq -r .owner "$cfg")}"
expect="${EXPECT_FAIL-deployer: balance covers the deploy fee and the gas, factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)}"
out="$(LAUNCH_CONFIG="$cfg" DEPLOYER="$deployer" forge script script/Preflight.s.sol --rpc-url "$rpc" --fork-block-number "$block" --sender "$deployer" 2>&1 || true)"
summary="$(grep -E '^ +[0-9]+ of [0-9]+ checks passed' <<<"$out" || true)"
if [ -z "$summary" ]; then
  echo "preflight did not finish its table:"; grep -E '^(Error|Warning)' <<<"$out" | head -5; exit 1
fi
failed="$(grep -E '^ +failed: ' <<<"$out" | sed -E 's/^ +failed: //' || true)"
echo "$summary" | sed 's/^ *//'
grep -oE '(CONFIG_HASH|CONTROLLER_NONCE)=[0-9a-fx]+' <<<"$out" | sort -u || true
if [ "$failed" != "$expect" ]; then
  echo "failed rows differ from the expected ones"; echo "  got:      $failed"; echo "  expected: $expect"; exit 1
fi
echo "ok: failed rows are exactly the expected ones (${failed:-none})"
