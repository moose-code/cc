#!/usr/bin/env bash
# regenerates the production interfaces from their abi.
# tests and scripts use these instead of importing the production sources, so they compile without via_ir.
# usage: script/tools/gen-interfaces.sh [--check|write] [contract]
# --check fails when a committed file differs; an optional contract limits the build and generation.
set -euo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-write}"
pairs=(Core:ICore ControllerV1:IControllerV1 CoreLib:ICoreLib FeeRouter:IFeeRouter CoreLens:ICoreLens CreditScoreLens:ICreditScoreLens)
if [ -n "${2:-}" ]; then
  selected=()
  for pair in "${pairs[@]}"; do
    if [ "${pair%%:*}" = "$2" ]; then selected+=("$pair"); fi
  done
  if [ "${#selected[@]}" = 0 ]; then echo "unknown contract: $2" >&2; exit 1; fi
  pairs=("${selected[@]}")
fi
sources=()
for pair in "${pairs[@]}"; do
  c="${pair%%:*}"
  if [ "$c" = CoreLib ]; then sources+=(src/lib/CoreLib.sol); else sources+=("src/$c.sol"); fi
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
forge build --quiet "${sources[@]}" 2>/dev/null
for pair in "${pairs[@]}"; do
  c="${pair%%:*}"; i="${pair##*:}"
  python3 -c "import json,sys;print(json.dumps(json.load(open('out/$c.sol/$c.json'))['abi']))" > "$tmp/$c.json"
  cast interface "$tmp/$c.json" -n "$i" -p '^0.8.28' -o "$tmp/$i.raw.sol" >/dev/null
  python3 script/tools/fix-interface.py "$tmp/$i.raw.sol" "$i" > "$tmp/$i.sol"
  if [ "$mode" = "--check" ]; then diff -q "$tmp/$i.sol" "src/interfaces/$i.sol"; else cp "$tmp/$i.sol" "src/interfaces/$i.sol"; fi
done
