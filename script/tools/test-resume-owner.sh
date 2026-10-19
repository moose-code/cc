#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
check=script/tools/check-resume-owner.sh

printf '%s\n' '  failed: predicted core is empty, predicted renderer is empty, predicted coin is empty, factory: deployToken accepts the config (simulated)' | "$check" 1
printf '%s\n' '  failed: factory: deployToken accepts the config (simulated)' | "$check" 1
printf '%s\n' '  failed: owner: no registered keys' | "$check" 0
for row in \
  'owner: code is the pinned EIP 7702 delegation' \
  'owner: delegate code hash is the pinned Calibur' \
  'owner: no registered keys' \
  'factory: owner is the deployer' \
  'v2: hook runtime matches pin'; do
  if printf '%s\n' "  failed: predicted core is empty, $row" | "$check" 1 >/dev/null; then
    echo "accepted failed owner row: $row" >&2; exit 1
  fi
done
if printf '%s\n' 'preflight crashed' | "$check" 1 >/dev/null; then
  echo "accepted a preflight failure without named rows" >&2; exit 1
fi
guard_log="$(mktemp)"
if STACK=master DRY_RUN=1 script/deploy.sh mainnet > /dev/null 2> "$guard_log"; then
  echo "accepted the master stack for a live deploy" >&2; exit 1
fi
if ! grep -q 'a live deploy requires STACK=live' "$guard_log"; then
  echo "the live stack guard did not run before network access" >&2; exit 1
fi
rm -f "$guard_log"
echo "resume preflight guard: 10 cases passed"
