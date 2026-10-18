#!/usr/bin/env bash
# builds Jack's balance token from the private repo jckbtchr-vv/credits at a pinned commit and writes
# out/upstream-balance.json, the artifact test/UpstreamBalance.t.sol and the production module variant of
# test/LaunchDayPhase2.t.sol load. a commit or build that differs from the pins below fails.
#
#   script/tools/upstream-balance.sh
#   UPSTREAM_DIR=<dir> script/tools/upstream-balance.sh    keep the checkout in <dir> and reuse it on the next run
#
# read access to the repository comes from GH_TOKEN, else UPSTREAM_CREDITS_TOKEN, else `gh auth token`. the token is
# passed to git on the command line only and is written to no file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="jckbtchr-vv/credits"
PIN=9318c713974ee18658ac5aeddab45f0e1e45b585
# sha256 of the ConversionLineageWithdrawals creation code
CREATION_SHA256=ecc7afbffdcebc9004e25f2e767e932fe697f266d28c33330862065ff00e98ae
# keccak256 of each artifact's deployedBytecode (immutables zeroed)
RUNTIME_CLW=0x29b369bc9814eaaf98e696df1a521200ad8584726f2fe036b3408a9d0bf3c3bd
RUNTIME_RENDERER=0xc8b64ac9f76c8e4afbb3cad2f840e077cec107ac16952f8d4bdd592a01b2df0b
RUNTIME_ARTWORK=0xc5b019615fa141d8092130f38868036d154105b0b57a3301ce70f85087d128ea

die() { echo "upstream-balance: $*" >&2; exit 1; }
for t in git forge cast jq; do command -v "$t" >/dev/null || die "$t is required"; done

TOKEN="${GH_TOKEN:-${UPSTREAM_CREDITS_TOKEN:-$(gh auth token 2>/dev/null || true)}}"
[ -n "$TOKEN" ] || die "no read token: set GH_TOKEN or run gh auth login"
AUTH="http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"

DIR="${UPSTREAM_DIR:-$(mktemp -d)}"
mkdir -p "$DIR"
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
  git -C "$DIR" remote add origin "https://github.com/$REPO.git"
fi
if [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)" != "$PIN" ]; then
  git -C "$DIR" -c "$AUTH" fetch -q --depth 1 origin "$PIN"
  git -C "$DIR" checkout -q --force FETCH_HEAD
fi
[ "$(git -C "$DIR" rev-parse HEAD)" = "$PIN" ] || die "checkout is not at $PIN"
git -C "$DIR" submodule update -q --init --depth 1 contracts/lib/openzeppelin-contracts contracts/lib/forge-std
git -C "$DIR" diff --quiet HEAD -- contracts/src contracts/foundry.toml || die "checkout differs from $PIN"

cd "$DIR/contracts"
forge build src/experimental/ConversionLineageWithdrawals.sol --skip test --skip script >"$DIR/forge-build.log" 2>&1 || { tail -30 "$DIR/forge-build.log" >&2; die "forge build failed"; }
OUT=out
art() { echo "$OUT/$1.sol/$1.json"; }

creation=$(jq -r '.bytecode.object' "$(art ConversionLineageWithdrawals)")
got=$(printf '%s' "${creation#0x}" | xxd -r -p | shasum -a 256 | cut -d' ' -f1)
[ "$got" = "$CREATION_SHA256" ] || die "creation code sha256 $got, expected $CREATION_SHA256"
check_runtime() {
  local got
  got=$(jq -r '.deployedBytecode.object' "$(art "$1")" | cast keccak)
  [ "$got" = "$2" ] || die "$1 runtime hash $got, expected $2"
}
check_runtime ConversionLineageWithdrawals "$RUNTIME_CLW"
check_runtime SurrenderedBalanceRenderer "$RUNTIME_RENDERER"
check_runtime LineageArtwork "$RUNTIME_ARTWORK"

mkdir -p "$ROOT/out"
jq --arg commit "$PIN" --arg rh "$RUNTIME_CLW" \
  '{upstreamCommit: $commit, contract: "ConversionLineageWithdrawals", abi, bytecode: {object: .bytecode.object}, deployedBytecode: {object: .deployedBytecode.object, immutableReferences: .deployedBytecode.immutableReferences}, runtimeHash: $rh}' \
  "$(art ConversionLineageWithdrawals)" > "$ROOT/out/upstream-balance.json"
echo "wrote $ROOT/out/upstream-balance.json from $REPO@$PIN"
