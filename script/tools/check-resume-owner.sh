#!/usr/bin/env bash
# A partial deploy can only fail preflight rows made false by contracts already created by this launch.
set -euo pipefail
[ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]] || { echo "invalid preflight status"; exit 1; }
[ "$1" -ne 0 ] || exit 0
failed="$(sed -nE 's/^ +failed: (.*)$/\1/p' | head -1)"
[ -n "$failed" ] || { echo "preflight failed without named rows"; exit 1; }
IFS=',' read -r -a rows <<< "$failed"
for row in "${rows[@]}"; do
  row="${row# }"
  case "$row" in
    'predicted core is empty'|'predicted renderer is empty'|'predicted coin is empty'|\
    'factory: deployToken accepts the config (simulated)') ;;
    *) echo "unsafe resume preflight row: $row"; exit 1 ;;
  esac
done
