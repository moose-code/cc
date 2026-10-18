#!/usr/bin/env bash
# promise: a deployed indexer reports unhealthy probes as failure without freeing its schema for another Core.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/indexer/env" "$TMP/deployments" "$TMP/bin"
cp "$ROOT/indexer/deploy.sh" "$TMP/indexer/deploy.sh"
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
exit 0
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case "$last" in
  */health/parity) printf '%s' "$MOCK_PARITY" ;;
  *) printf '200' ;;
esac
EOF
chmod +x "$TMP/bin/fly" "$TMP/bin/curl"

A=0x1111111111111111111111111111111111111111
B=0x2222222222222222222222222222222222222222
record() {
  jq -n --arg core "$1" \
    '{core:$core,coin:"0x3333333333333333333333333333333333333333",
      credits:"0x4444444444444444444444444444444444444444",
      statements:"0x5555555555555555555555555555555555555555",deployBlock:1}' \
    > "$TMP/deployments/1.json"
}
record "$A"
if MOCK_PARITY=503 PATH="$TMP/bin:$PATH" PROBE_ATTEMPTS=1 bash "$TMP/indexer/deploy.sh" mainnet > "$TMP/out" 2>&1; then
  echo "unhealthy parity was accepted" >&2
  exit 1
fi
grep -q '/health/parity: 503' "$TMP/out"
[[ "$(jq -r .cc_test "$TMP/indexer/deployments.json")" == "$A" ]]

record "$B"
if MOCK_PARITY=200 PATH="$TMP/bin:$PATH" PROBE_ATTEMPTS=1 bash "$TMP/indexer/deploy.sh" mainnet > "$TMP/out" 2>&1; then
  echo "schema reuse for another Core was accepted" >&2
  exit 1
fi
grep -q "was used for $A" "$TMP/out"

record "$A"
MOCK_PARITY=200 PATH="$TMP/bin:$PATH" PROBE_ATTEMPTS=1 bash "$TMP/indexer/deploy.sh" mainnet > "$TMP/out" 2>&1
grep -q '/health/parity: 200' "$TMP/out"
echo "indexer deploy guards passed"
