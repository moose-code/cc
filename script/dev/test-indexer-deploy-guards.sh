#!/usr/bin/env bash
# promise: an indexer binds its schema, rejects unhealthy SQL, and accepts only matching coinLive/code states.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/indexer/env" "$TMP/deployments" "$TMP/bin"
cp "$ROOT/indexer/deploy.sh" "$TMP/indexer/deploy.sh"
cp "$ROOT/indexer/check-live.sh" "$TMP/indexer/check-live.sh"
cat > "$TMP/indexer/env/mainnet.env" <<'EOF'
CHAIN_ID=1
TARGET=fly
DATABASE_SCHEMA=cc_test
FLY_CONFIG=fly.toml
CREDITS_START_BLOCK=1
STATEMENTS_START_BLOCK=1
STRATEGY_START_BLOCK=1
EOF
echo 'app = "cc-test"' > "$TMP/indexer/fly.toml"
cat > "$TMP/bin/fly" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == deploy ]]; then [[ " $* " == *" --ha=false "* ]] || exit 9; fi
exit 0
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/cast" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  chain-id) echo 1 ;;
  block-number) echo 301 ;;
  code) echo "${MOCK_COIN_CODE:-0x}" ;;
  call)
    case "$3" in
      COIN*) echo 0x3333333333333333333333333333333333333333 ;;
      *) echo 0 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/node" <<'EOF'
#!/usr/bin/env bash
[[ "${*: -1}" == 1 ]] || exit 2
if [[ "$MOCK_NODE_EXIT" != 0 ]]; then echo "mock SQL acceptance failed" >&2; fi
exit "$MOCK_NODE_EXIT"
EOF
chmod +x "$TMP/bin/fly" "$TMP/bin/curl" "$TMP/bin/cast" "$TMP/bin/node"

A=0x1111111111111111111111111111111111111111
B=0x2222222222222222222222222222222222222222
record() {
  jq -n --arg core "$1" --argjson live "${2:-false}" \
    '{core:$core,coin:"0x3333333333333333333333333333333333333333",
      credits:"0x4444444444444444444444444444444444444444",
      statements:"0x5555555555555555555555555555555555555555",deployBlock:1,coinLive:$live}' \
    > "$TMP/deployments/1.json"
}
record "$A"
PATH="$TMP/bin:$PATH" bash "$TMP/indexer/deploy.sh" mainnet > "$TMP/out" 2>&1
grep -q "schema cc_test is bound to $A" "$TMP/out"
[[ "$(jq -r .cc_test "$TMP/indexer/deployments.json")" == "$A" ]]

record "$B"
if PATH="$TMP/bin:$PATH" bash "$TMP/indexer/deploy.sh" mainnet > "$TMP/out" 2>&1; then
  echo "schema reuse for another Core was accepted" >&2
  exit 1
fi
grep -q "was used for $A" "$TMP/out"

record "$A"
if MOCK_NODE_EXIT=1 RPC_URL=http://read.invalid PATH="$TMP/bin:$PATH" bash "$TMP/indexer/check-live.sh" mainnet > "$TMP/out" 2>&1; then
  echo "unhealthy SQL acceptance was accepted" >&2
  exit 1
fi
grep -q "mock SQL acceptance failed" "$TMP/out"
MOCK_NODE_EXIT=0 RPC_URL=http://read.invalid PATH="$TMP/bin:$PATH" bash "$TMP/indexer/check-live.sh" mainnet > "$TMP/out" 2>&1
grep -q 'production read-only acceptance passed' "$TMP/out"
record "$A" true
if MOCK_NODE_EXIT=0 RPC_URL=http://read.invalid PATH="$TMP/bin:$PATH" bash "$TMP/indexer/check-live.sh" mainnet > "$TMP/out" 2>&1; then
  echo "coinLive=true with no coin code was accepted" >&2
  exit 1
fi
grep -q 'coinLive=true but coin has no valid code' "$TMP/out"
MOCK_NODE_EXIT=0 MOCK_COIN_CODE=0x1234 RPC_URL=http://read.invalid PATH="$TMP/bin:$PATH" bash "$TMP/indexer/check-live.sh" mainnet > "$TMP/out" 2>&1
grep -q 'production read-only acceptance passed' "$TMP/out"
record "$A" false
if MOCK_NODE_EXIT=0 MOCK_COIN_CODE=0x1234 RPC_URL=http://read.invalid PATH="$TMP/bin:$PATH" bash "$TMP/indexer/check-live.sh" mainnet > "$TMP/out" 2>&1; then
  echo "coinLive=false with deployed coin code was accepted" >&2
  exit 1
fi
grep -q 'coinLive=false but coin has code' "$TMP/out"
echo "indexer deploy guards passed"
