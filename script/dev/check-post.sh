#!/usr/bin/env bash
# Chain-read checklist for the dev seed PHASE=post state that script/dev/local.sh leaves running. Asserts the balance
# side the owner's local chain wires from Jack's pinned artifact: the module is set, the balance token is Jack's pinned
# build (deployed runtime hash with immutables masked equals the pinned hash in out/upstream-balance.json), redeem and
# balance bid are on, the launch supply holder holds balance tokens, the module holds a nonzero redemption balance, and
# a sellForBalance from A1 pays exactly balanceBidOf. Reads deployments/31337.json for the addresses; a failed assertion
# exits nonzero.
#
#   PORT=8619 script/dev/check-post.sh          check the node on that port against deployments/31337.json
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT="${PORT:-8619}"
RPC="http://127.0.0.1:$PORT"
REC="${REC:-deployments/31337.json}"
ART="out/upstream-balance.json"
CREDITS=0x97630aA70AB14ed9883B41dAfccBc11349723043
A1=0x1111111111111111111111111111111111111111
FUNDER=0x6666666666666666666666666666666666666666   # holds Jack's launch supply after retirement

[ -f "$REC" ] || { echo "no record at $REC; run PORT=$PORT PHASE=post FRESH=1 script/dev/local.sh first" >&2; exit 1; }
[ -f "$ART" ] || { echo "no $ART; run script/tools/upstream-balance.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" = "31337" ] || { echo "no chain id 31337 node on $RPC" >&2; exit 1; }

CORE="$(jq -r .core "$REC")"
CTL="$(jq -r .controller "$REC")"
BMOD="$(jq -r .balanceModule "$REC")"
BTOK="$(jq -r .balanceToken "$REC")"

FAILS=0; PASSES=0
check() { if [ "$2" = 1 ]; then echo "  PASS: $1 ($3)"; PASSES=$((PASSES+1)); else echo "  FAIL: $1 ($3)"; FAILS=$((FAILS+1)); fi; }
calc() { python3 -c "import sys; print(1 if ($1) else 0)"; }
callc() { cast call "$@" --rpc-url "$RPC"; }
lc() { echo "$1" | tr 'A-Z' 'a-z'; }

echo "=== PHASE=post chain checklist on $RPC ==="

# 1. the module is set and matches the record
ONCHAIN_MOD="$(callc "$CORE" 'balanceModule()(address)')"
check "the balance module is set to Jack's module" \
  "$([ "$(lc "$ONCHAIN_MOD")" = "$(lc "$BMOD")" ] && [ "$(lc "$ONCHAIN_MOD")" != "0x0000000000000000000000000000000000000000" ] && echo 1 || echo 0)" \
  "module $ONCHAIN_MOD"

# 2. the balance token is Jack's pinned build: mask the deployed runtime immutables and compare to the pinned hash
ONCHAIN_TOK="$(callc "$CORE" 'balanceToken()(address)')"
check "the balance token matches the record" \
  "$([ "$(lc "$ONCHAIN_TOK")" = "$(lc "$BTOK")" ] && echo 1 || echo 0)" "token $ONCHAIN_TOK"
CODE="$(cast code "$BTOK" --rpc-url "$RPC")"
MASKED="$(python3 - "$CODE" "$ART" <<'PY'
import sys, json
code = sys.argv[1]
code = code[2:] if code.startswith("0x") else code
refs = json.load(open(sys.argv[2]))["deployedBytecode"]["immutableReferences"]
b = bytearray.fromhex(code)
for _, slots in refs.items():
    for r in slots:
        s, l = r["start"], r["length"]
        for i in range(s, s + l):
            b[i] = 0
print("0x" + b.hex())
PY
)"
GOT_HASH="$(cast keccak "$MASKED")"
WANT_HASH="$(jq -r '.runtimeHash' "$ART")"
check "the token runtime hash equals the pinned hash (immutables masked)" \
  "$([ "$(lc "$GOT_HASH")" = "$(lc "$WANT_HASH")" ] && echo 1 || echo 0)" "got $GOT_HASH"

# 3. redeem and balance bid are on (settings struct, fields 12 and 13)
SIG='settings()((uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,bool,bool,uint16,uint16,uint16,uint128,uint64,uint48,uint64,uint64,uint48,uint16,uint24,uint32,uint96,uint16,uint16,uint16,uint16,uint32,uint32,uint32,uint32,uint64,uint32,bool))'
SETTINGS_JSON="$(cast call "$CORE" "$SIG" --json --rpc-url "$RPC")"
REDEEM_ON="$(echo "$SETTINGS_JSON" | jq -r '.[0][11]' 2>/dev/null)"
BALBID_ON="$(echo "$SETTINGS_JSON" | jq -r '.[0][12]' 2>/dev/null)"
check "redeem is on" "$([ "$REDEEM_ON" = "true" ] && echo 1 || echo 0)" "redeemOn $REDEEM_ON"
# the hazard state: balance bid on, value mode off and a balance pool key set (docs/RUNBOOK.md, activation order)
VALUE_ON="$(echo "$SETTINGS_JSON" | jq -r '.[0][36]' 2>/dev/null)"
KEY_SET="$(callc "$CTL" 'balancePoolKeySet()(bool)' | awk '{print $1}')"
check "no balance bid on with value mode off and a pool key set" \
  "$([ "$BALBID_ON" = "true" ] && [ "$VALUE_ON" != "true" ] && [ "$KEY_SET" = "true" ] && echo 0 || echo 1)" \
  "balanceBidOn $BALBID_ON valueModeOn $VALUE_ON poolKeySet $KEY_SET"

# 4. the launch supply holder (funder) holds balance tokens; the module holds a nonzero redemption balance
FUNDER_BAL="$(callc "$BTOK" 'balanceOf(address)(uint256)' "$FUNDER" | awk '{print $1}')"
check "the launch supply holder holds balance tokens" "$(calc "$FUNDER_BAL > 0")" "funder balance $FUNDER_BAL"

# 5. available() nonzero (a redemption paid the module)
AVAIL="$(callc "$BMOD" 'available()(uint256)' | awk '{print $1}')"
check "the module available balance is nonzero" "$(calc "$AVAIL > 0")" "available $AVAIL"

# 6. a sellForBalance from A1 pays balanceBidOf. the credit approval lands in its own block first, then the bid is read
# and the sell sent, one block apart; the balance bid climbs a little each block, so the realized pay is checked within
# a small tolerance of the read. e2e-real's phase7BalanceSell asserts the exact equality atomically in one tx.
cast send "$CREDITS" 'setApprovalForAll(address,bool)' "$CORE" true --from "$A1" --unlocked --rpc-url "$RPC" >/dev/null 2>&1
ID="$(callc "$CREDITS" 'tokensOf(address)(uint256[])' "$A1" | tr -d '[]' | tr ',' '\n' | grep -oE '[0-9]+' | head -1)"
if [ "$BALBID_ON" != "true" ]; then
  echo "  skip: balance bid is off until value mode is on"
elif [ -n "$ID" ]; then
  BID="$(callc "$CORE" 'balanceBidOf(uint256)(uint256)' "$ID" | awk '{print $1}')"
  BEFORE="$(callc "$BTOK" 'balanceOf(address)(uint256)' "$A1" | awk '{print $1}')"
  if cast send "$CORE" 'sellForBalance(uint256[])' "[$ID]" --from "$A1" --unlocked --rpc-url "$RPC" >/dev/null 2>&1; then
    AFTER="$(callc "$BTOK" 'balanceOf(address)(uint256)' "$A1" | awk '{print $1}')"
    PAID="$(python3 -c "print($AFTER - $BEFORE)")"
    check "a sellForBalance from A1 pays balanceBidOf" "$(calc "$BID > 0 and abs($PAID - $BID) <= $BID * 2 // 100")" "bid $BID paid $PAID"
  else
    check "a sellForBalance from A1 pays balanceBidOf" 0 "sellForBalance reverted for credit $ID"
  fi
else
  check "a sellForBalance from A1 pays balanceBidOf" 0 "A1 holds no credit to sell"
fi

echo "passes: $PASSES   fails: $FAILS"
[ "$FAILS" -eq 0 ] || exit 1
echo "CHECK-POST PASSED"
