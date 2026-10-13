#!/usr/bin/env bash
# Deploy CreditScoreLens, or retry verification: bash script/deploy-credit-score-lens.sh verify <address>
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
[[ "$(git branch --show-current)" == main ]] || { echo 'Run this script from main.' >&2; exit 1; }
rpc="${TENDERLY_RPC_URL:-https://mainnet.gateway.tenderly.co}"
sender=0xCB43078C32423F5348Cab5885911C3B5faE217F9
mode="${1:-deploy}"
[[ "$mode" == deploy || "$mode" == verify ]] || { echo 'Usage: deploy-credit-score-lens.sh [verify <address>]' >&2; exit 1; }
if [[ "$mode" == verify ]]; then
  lens="${2:-}"
  [[ "$lens" =~ ^0x[0-9a-fA-F]{40}$ && "$lens" != 0x0000000000000000000000000000000000000000 ]] || { echo 'Provide the deployed lens address.' >&2; exit 1; }
fi
forge build src/CreditScoreLens.sol script/DeployCreditScoreLens.s.sol script/VerifyCreditScoreLens.s.sol
python3 - <<'CHECK'
import json, subprocess
artifact = json.load(open('out/CreditScoreLens.sol/CreditScoreLens.json'))
metadata = artifact['metadata']; settings = metadata['settings']
if (metadata['compiler']['version'].split('+')[0] != '0.8.30' or not settings.get('viaIR')
        or settings['optimizer'] != {'enabled': True, 'runs': 200}
        or settings['evmVersion'] != 'cancun' or settings['metadata']['bytecodeHash'] != 'none'):
    raise SystemExit('Helper compiler settings differ from the reviewed build.')
code_hash = subprocess.check_output(['cast', 'keccak', artifact['deployedBytecode']['object']], text=True).strip()
if code_hash != '0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058':
    raise SystemExit('Helper bytecode differs from the reviewed build.')
CHECK
# A .git boundary prevents Foundry from loading ancestor .env wallet settings, even under project-local TMPDIR.
preview_dir="$(mktemp -d)"
trap 'rm -rf "$preview_dir"' EXIT
mkdir "$preview_dir/.git"
readonly_script() {
  (cd "$preview_dir" && env -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD \
    -u ETH_PRIVATE_KEY -u PRIVATE_KEY -u TEMPO_ACCESS_KEY -u TURNKEY_API_PRIVATE_KEY \
    -u AWS_KMS_KEY_ID -u GCP_KEY_NAME \
    FOUNDRY_BROADCAST="$preview_dir/broadcast" \
    forge script "$repo_dir/script/$1" --root "$repo_dir" --rpc-url "$rpc" --sender "$sender")
}
if [[ "$mode" == deploy ]]; then
  echo 'Gas preview, no wallet or transaction:'
  readonly_script DeployCreditScoreLens.s.sol
  read -rp 'Continue to unlock ripe0x and deploy? [y/N] ' answer
  [[ "$answer" == y || "$answer" == Y ]] || { echo 'Cancelled, nothing sent.'; exit 0; }
fi
if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  ETHERSCAN_API_KEY="$(forge config --json | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c.get("etherscan_api_key") or next((v.get("key", "") for k,v in c.get("etherscan", {}).items() if v.get("chain") in (1,"1","mainnet") or (k=="mainnet" and not v.get("chain"))), ""))')"
fi
if [[ -z "$ETHERSCAN_API_KEY" || "$ETHERSCAN_API_KEY" == *'${'* ]]; then
  [[ -t 0 ]] || { echo 'Set ETHERSCAN_API_KEY or run in a terminal.' >&2; exit 1; }
  read -rsp 'Etherscan API key (hidden): ' ETHERSCAN_API_KEY
  echo
fi
[[ -n "$ETHERSCAN_API_KEY" ]] || { echo 'Etherscan API key is required.' >&2; exit 1; }
export ETHERSCAN_API_KEY
if [[ "$mode" == deploy ]]; then
  mkdir -p broadcast
  record_dir="$(mktemp -d "$repo_dir/broadcast/credit-score-lens-XXXXXX")"
  FOUNDRY_BROADCAST="$record_dir" forge script script/DeployCreditScoreLens.s.sol \
    --rpc-url "$rpc" --sender "$sender" --account ripe0x --broadcast --slow
  lens="$(python3 - "$record_dir/DeployCreditScoreLens.s.sol/1/run-latest.json" <<'RECEIPT'
import json, re, sys
record = json.load(open(sys.argv[1])); txs = record.get('transactions', []); receipts = record.get('receipts', [])
if record.get('chain') != 1 or record.get('pending') or len(txs) != 1 or len(receipts) != 1:
    raise SystemExit('Expected one confirmed mainnet deployment; inspect the broadcast record before retrying.')
tx, receipt = txs[0], receipts[0]
creation = json.load(open('out/CreditScoreLens.sol/CreditScoreLens.json'))['bytecode']['object']
body = tx.get('transaction', {}); value = body.get('value', '0x0')
value = int(value, 0) if isinstance(value, str) else int(value)
lens = receipt.get('contractAddress', '')
if (tx.get('transactionType') != 'CREATE' or tx.get('contractName') != 'CreditScoreLens'
        or body.get('input') != creation or value != 0 or receipt.get('status') not in (1, '0x1')
        or not tx.get('hash') or tx['hash'] != receipt.get('transactionHash')
        or not re.fullmatch(r'0x[0-9a-fA-F]{40}', lens) or int(lens, 16) == 0
        or lens.lower() != tx.get('contractAddress', '').lower()):
    raise SystemExit('Deployment receipt mismatch; inspect the broadcast record before retrying.')
print(lens)
RECEIPT
)"
  echo "Deployed CreditScoreLens: $lens"
  echo "If verification fails, retry: bash script/deploy-credit-score-lens.sh verify $lens"
fi
LENS_ADDRESS="$lens" readonly_script VerifyCreditScoreLens.s.sol
forge verify-contract "$lens" src/CreditScoreLens.sol:CreditScoreLens --chain 1 \
  --rpc-url "$rpc" --compilation-profile viair --watch
