#!/usr/bin/env bash
# A partial deploy can fail ordinary preflight rows. Every resume still requires the current owner delegation pins.
set -euo pipefail
[ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]] || { echo "invalid preflight status"; exit 1; }
[ "$1" -ne 0 ] || exit 0
failed="$(sed -nE 's/^ +failed: (.*)$/\1/p' | head -1)"
[ -n "$failed" ] || { echo "preflight failed without named rows"; exit 1; }
case ", $failed" in
  *", owner:"*) echo "owner preflight failed: $failed"; exit 1 ;;
esac
