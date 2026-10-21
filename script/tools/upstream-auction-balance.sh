#!/usr/bin/env bash
# builds the phase 2 balance token, InterfaceAuctionWithdrawals, from the private repo jckbtchr-vv/credits at the
# reviewed commit and writes out/upstream-auction-balance.json, the artifact test/Phase2UpstreamBalance.t.sol loads.
# the older ConversionLineageWithdrawals pin stays in script/tools/upstream-balance.sh for the tests written against it.
# a commit or build that differs from the pins below fails.
#
#   script/tools/upstream-auction-balance.sh
#   UPSTREAM_DIR=<dir> script/tools/upstream-auction-balance.sh    keep the checkout in <dir> and reuse it on the next run
# GitHub CLI supplies read credentials through Git's credential-helper protocol. GH_TOKEN takes precedence over
# UPSTREAM_CREDITS_TOKEN; when neither is set, the CLI uses its existing login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="jckbtchr-vv/credits"
PIN=54ef94cf9066f5f31bce493f06167afc4640b2f2
# sha256 of the InterfaceAuctionWithdrawals creation code (solc 0.8.28, via_ir, prague, the upstream profile)
CREATION_SHA256=f706ace186e444c8bf927d4c6661ce70064757aa6bab615a3abb85d5b5862248
# keccak256 of each artifact's deployedBytecode (immutables zeroed)
RUNTIME_IAW=0x6185ba36a0007d4864b5222a88e7a0d5ea2aa1a7fce8f0827c2552dd38407d43
RUNTIME_RENDERER=0x62c4c14180210800c660362a08e4e7a827398758a1ee034b49d7b1c5f6595a30
RUNTIME_ARTWORK=0xf7f4d679477f21c256ba810a3b4c56b2e8f72c7565cb489abc9081348759e9f2

die() { echo "upstream-balance: $*" >&2; exit 1; }
for t in git gh forge cast jq python3; do command -v "$t" >/dev/null || die "$t is required"; done
if [ -z "${GH_TOKEN:-}" ] && [ -n "${UPSTREAM_CREDITS_TOKEN:-}" ]; then
  export GH_TOKEN="$UPSTREAM_CREDITS_TOKEN"
fi

DIR="${UPSTREAM_DIR:-$(mktemp -d)}"
mkdir -p "$DIR"
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
  git -C "$DIR" remote add origin "https://github.com/$REPO.git"
fi
if [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)" != "$PIN" ]; then
  GIT_TERMINAL_PROMPT=0 git -C "$DIR" -c credential.helper= -c credential.helper='!gh auth git-credential' \
    fetch -q --depth 1 origin "$PIN"
  git -C "$DIR" checkout -q --force FETCH_HEAD
fi
[ "$(git -C "$DIR" rev-parse HEAD)" = "$PIN" ] || die "checkout is not at $PIN"
GIT_TERMINAL_PROMPT=0 git -C "$DIR" -c credential.helper= -c credential.helper='!gh auth git-credential' \
  submodule update -q --init --depth 1 contracts/lib/openzeppelin-contracts contracts/lib/forge-std
git -C "$DIR" diff --quiet HEAD -- contracts/src contracts/foundry.toml || die "checkout differs from $PIN"

cd "$DIR/contracts"
forge build src/experimental/InterfaceAuctionWithdrawals.sol --skip test --skip script >"$DIR/forge-build.log" 2>&1 || { tail -30 "$DIR/forge-build.log" >&2; die "forge build failed"; }
OUT=out
art() { echo "$OUT/$1.sol/$1.json"; }

creation=$(jq -r '.bytecode.object' "$(art InterfaceAuctionWithdrawals)")
got=$(printf '%s' "${creation#0x}" | python3 -I -c 'import sys,hashlib;print(hashlib.sha256(bytes.fromhex(sys.stdin.read().strip())).hexdigest())')
[ "$got" = "$CREATION_SHA256" ] || die "creation code sha256 $got, expected $CREATION_SHA256"
check_runtime() {
  local got
  got=$(jq -r '.deployedBytecode.object' "$(art "$1")" | cast keccak)
  [ "$got" = "$2" ] || die "$1 runtime hash $got, expected $2"
}
check_runtime InterfaceAuctionWithdrawals "$RUNTIME_IAW"
check_runtime SurrenderedBalanceRenderer "$RUNTIME_RENDERER"
check_runtime LineageArtwork "$RUNTIME_ARTWORK"

mkdir -p "$ROOT/out"
jq --arg commit "$PIN" --arg rh "$RUNTIME_IAW" \
  '{upstreamCommit: $commit, contract: "InterfaceAuctionWithdrawals", abi, bytecode: {object: .bytecode.object}, deployedBytecode: {object: .deployedBytecode.object, immutableReferences: .deployedBytecode.immutableReferences}, runtimeHash: $rh}' \
  "$(art InterfaceAuctionWithdrawals)" > "$ROOT/out/upstream-auction-balance.json"
echo "wrote $ROOT/out/upstream-auction-balance.json from $REPO@$PIN"
