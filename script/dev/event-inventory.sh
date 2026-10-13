#!/usr/bin/env bash
# prints, for the Core, the controller and the fee router, every event in the ABI with the number of times it fired in
# the scanned block range, and a reason for every event that never fired. the ABI is the three production interfaces;
# the topic of each event comes from `forge inspect`, the counts from `eth_getLogs` on the local node.
#
#   RPC_URL=http://127.0.0.1:8546 FROM_BLOCK=26158123 \
#   CORE=0x.. CTL=0x.. ROUTER=0x.. PHASE=post script/dev/event-inventory.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${RPC_URL:-http://127.0.0.1:8546}"
FROM_BLOCK="${FROM_BLOCK:?FROM_BLOCK (decimal deploy block) required}"
CORE="${CORE:?CORE required}"
CTL="${CTL:?CTL required}"
ROUTER="${ROUTER:?ROUTER required}"
PHASE="${PHASE:-post}"

FROM_HEX="$(printf '0x%x' "$FROM_BLOCK")"

# a reason for an event that did not fire. phase aware for the exit side.
reason() {
  case "$1" in
    ExitModuleSet|StatementExited|RedeemBurnReleased|UnitPerPointRefreshed|ExitPoolKeySet)
      [ "$PHASE" = "pre" ] && { echo "exit side, PHASE=post only"; return; }
      echo "not exercised this run" ;;
    CoinRescued|NftRescued) echo "owner asset rescue, outside the value flow" ;;
    ControllerLocked|SuccessorLocked|TargetsLocked) echo "permanent lock, not exercised" ;;
    EngineRetired|Migrated|ExitTokenMigrationSkipped) echo "migrate retires the engine, excluded" ;;
    SuccessorSet) echo "successor handover setup, not exercised" ;;
    OwnershipTransferStarted|OwnershipTransferred) echo "ownership handover, not exercised (set at deploy, before range)" ;;
    TargetAdded|TargetRemoved) echo "owner target management, not exercised" ;;
    MinCcToChooseSet|CreditCostToPotBpsSet) echo "core credit setting, left at launch" ;;
    Skimmed) echo "no forced eth or exit token to skim" ;;
    ListingBought) echo "no local listing sits below the bid; Seaport needs an external signed order" ;;
    ExitModuleLocked) echo "permanent lock, not exercised" ;;
    Locked) echo "router lock, not exercised" ;;
    Claimed) echo "no payee claim performed" ;;
    PayeeOwed) echo "the payee was paid on flush, nothing left owed" ;;
    AnchorBpsSet|AnchorHalfLifeSet|AnchorMinCostSet) echo "anchor setting, left at launch" ;;
    FastDecayBpsPerHourSet|SlowDecayBpsPerHourSet|KneeBpsSet|StartCapBpsSet|FloorBpsSet) echo "extra sale setting, left at launch" ;;
    CreditFloorBpsSet|CreditStartBpsSet) echo "extra credit setting, left at launch" ;;
    *) echo "not exercised this run" ;;
  esac
}

# topic0 -> count of logs this address emitted in the range
declare -A COUNT
tally() {
  local addr="$1"
  local json
  json="$(cast rpc eth_getLogs \
    "{\"fromBlock\":\"$FROM_HEX\",\"toBlock\":\"latest\",\"address\":\"$addr\"}" --rpc-url "$RPC_URL")"
  while read -r t; do
    [ -n "$t" ] || continue
    COUNT["$t"]=$(( ${COUNT["$t"]:-0} + 1 ))
  done < <(printf '%s' "$json" | jq -r '.[].topics[0] // empty')
}

# one contract: its interface's events, the counts for its address, fired first then the rest with a reason
section() {
  local title="$1" iface="$2" addr="$3"
  echo
  echo "--- $title ($addr) ---"
  local fired="" idle=""
  while IFS='|' read -r sig topic; do
    sig="$(echo "$sig" | tr -d ' ')"
    topic="$(echo "$topic" | tr -d ' ')"
    [ -n "$topic" ] || continue
    local name="${sig%%(*}"
    local c="${COUNT[$topic]:-0}"
    if [ "$c" -gt 0 ]; then
      fired+="$(printf '  %-28s %d\n' "$name" "$c")"$'\n'
    else
      idle+="$(printf '  %-28s 0   (%s)\n' "$name" "$(reason "$name")")"$'\n'
    fi
  done < <(forge inspect "$iface" events 2>/dev/null | grep -E '^\|.*0x[0-9a-f]{64}' | awk -F'|' '{print $2 "|" $3}')
  printf '%s' "$fired"
  [ -n "$idle" ] && { echo "  (never fired)"; printf '%s' "$idle"; }
}

tally "$CORE"
tally "$CTL"
tally "$ROUTER"

echo "=== event inventory (phase $PHASE, blocks $FROM_BLOCK..latest) ==="
section "Core" "src/interfaces/ICore.sol:ICore" "$CORE"
section "ControllerV1" "src/interfaces/IControllerV1.sol:IControllerV1" "$CTL"
section "FeeRouter" "src/interfaces/IFeeRouter.sol:IFeeRouter" "$ROUTER"
