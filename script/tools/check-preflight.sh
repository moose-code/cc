#!/usr/bin/env bash
# runs `forge script script/Preflight.s.sol` on a fork of the pin block, the way docs/RUNBOOK.md step 4 runs it, and
# compares the failed rows with the expected ones. a script only failure (a cheatcode that is refused in a script
# context, a revert outside the rows) leaves the table unprinted and fails here. tests call the checks through a test
# contract and cannot see that class of failure.
# it also checks what forge cannot (ffi is off): the git tree is clean and HEAD contains the frozen candidate recorded
# in the freeze table of docs/STATUS.md (docs/RUNBOOK.md step 4). a pending candidate row skips the containment check. the build pins are preflight rows (script/Checks.sol).
# usage: script/tools/check-preflight.sh [config.json]
#        the config defaults to script/config/mainnet.json, the file the launch uses. the rehearsal passes
#        script/config/rehearsal.json explicitly.
# the row `rule: image and description are empty or real values, not placeholders` is expected to fail only when the
# config holds the text PLACEHOLDER in `image` or `description` (the rehearsal file, by design). an empty value passes:
# the coin renderer draws the image and reads the description from the coin.
# env:   MAINNET_RPC_URL (default: the Tenderly public gateway, archive state), FORK_BLOCK (default 26158000),
#        DEPLOYER (default: the config owner), EXPECT_FAIL (comma separated failed rows; default: the two factory rows of
#        DEPLOY step 3, and the metadata row for a config holding PLACEHOLDER). the balance row
#        `deployer: balance covers the deploy fee and the gas` is compared. the default pin block run fails on it
#        because the owner held 0.068 eth at that block, below the need.
#        IGNORE_BALANCE=1 leaves the balance row out of the comparison on both sides. a reproducible pin block run uses
#        it. the launch day run uses FORK_BLOCK=<latest block> with the funded owner and no IGNORE_BALANCE, so an
#        underfunded deployer fails here.
set -euo pipefail
cd "$(dirname "$0")/../.."
cfg="${1:-script/config/mainnet.json}"
candidate="$(awk -F'|' '$2 ~ /^ *candidate *$/ {gsub(/ /,"",$3); print $3}' docs/STATUS.md)"
dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then echo "git tree is not clean:"; head -10 <<<"$dirty"; exit 1; fi
if [ "$candidate" = pending ] || [ -z "$candidate" ]; then
  echo "ok: git tree clean, no frozen candidate recorded yet (docs/STATUS.md)"
elif ! git merge-base --is-ancestor "$candidate" HEAD; then
  echo "HEAD $(git rev-parse --short HEAD) does not contain the frozen candidate ${candidate:0:7}"; exit 1
else
  echo "ok: git tree clean, HEAD $(git rev-parse --short HEAD) contains the frozen candidate ${candidate:0:7}"
fi
rpc="${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}"
block="${FORK_BLOCK:-26158000}"
deployer="${DEPLOYER:-$(jq -r .owner "$cfg")}"
imgrow="rule: image and description are empty or real values, not placeholders"
balrow="deployer: balance covers the deploy fee and the gas"
owner_rows="factory: deployToken accepts the config (simulated)"
if jq -e '[.image, .description] | any(contains("PLACEHOLDER"))' "$cfg" >/dev/null; then owner_rows="$imgrow, $owner_rows"; fi
expect="${EXPECT_FAIL-$owner_rows}"
out="$(LAUNCH_CONFIG="$cfg" DEPLOYER="$deployer" forge script script/Preflight.s.sol --rpc-url "$rpc" --fork-block-number "$block" --sender "$deployer" 2>&1 || true)"
summary="$(grep -E '^ +[0-9]+ of [0-9]+ checks passed' <<<"$out" || true)"
if [ -z "$summary" ]; then
  echo "preflight did not finish its table:"; grep -E '^(Error|Warning)' <<<"$out" | head -5; exit 1
fi
failed="$(grep -E '^ +failed: ' <<<"$out" | sed -E 's/^ +failed: //' || true)"
echo "$summary" | sed 's/^ *//'
grep -oE 'CONFIG_HASH=[0-9a-fx]+' <<<"$out" | sort -u || true
# the failed rows without the balance row, in the same ", " joined form as the expected rows
without_balance() { { sed 's/, /\n/g' <<<"$1" | grep -vxF "$balrow" || true; } | paste -sd, - | sed 's/,/, /g'; }
if [ "${IGNORE_BALANCE:-0}" = 1 ]; then
  failed="$(without_balance "$failed")"
  expect="$(without_balance "$expect")"
fi
if [ "$failed" != "$expect" ]; then
  echo "failed rows differ from the expected ones"; echo "  got:      $failed"; echo "  expected: $expect"; exit 1
fi
echo "ok: failed rows are exactly the expected ones (${failed:-none})"
