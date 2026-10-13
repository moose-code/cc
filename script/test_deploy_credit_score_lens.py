"""Exercise the shell CLI without a real wallet, broadcast or explorer submission."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LENS = '0x' + '12' * 20


class DeployCreditScoreLensTest(unittest.TestCase):
    def invoke(self, args=(), answer='', branch='main', corrupt=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'script').mkdir(); (root / 'bin').mkdir(); (root / 'out/CreditScoreLens.sol').mkdir(parents=True)
            shutil.copyfile(ROOT / 'script/deploy-credit-score-lens.sh', root / 'script/deploy-credit-score-lens.sh')
            artifact = json.loads((ROOT / 'out/CreditScoreLens.sol/CreditScoreLens.json').read_text())
            if corrupt:
                artifact['deployedBytecode']['object'] = '0x6000'
            (root / 'out/CreditScoreLens.sol/CreditScoreLens.json').write_text(json.dumps(artifact))
            (root / 'bin/git').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$TEST_BRANCH"\n')
            (root / 'bin/forge').write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
if args[0] == 'config':
    print(json.dumps({'etherscan_api_key': 'test-api-key'}))
elif args[0] == 'script' and '--broadcast' not in args:
    assert pathlib.Path('.git').is_dir()
    assert 'ETH_KEYSTORE_ACCOUNT' not in os.environ
    if 'DeployCreditScoreLens' in args[1]:
        print('Estimated amount required: 0.0001 ETH')
    else:
        assert os.environ.get('LENS_ADDRESS') == '0x' + '12' * 20
        print('Source results match.')
elif '--broadcast' in args:
    assert args[args.index('--account') + 1] == 'ripe0x'
    assert os.environ.get('ETHERSCAN_API_KEY') == 'test-api-key'
    print('Keystore password (mock only)')
    lens = '0x' + '12' * 20; tx_hash = '0x' + 'ab' * 32
    code = json.load(open('out/CreditScoreLens.sol/CreditScoreLens.json'))['bytecode']['object']
    record = {'chain': 1, 'pending': [], 'transactions': [{'transactionType': 'CREATE', 'contractName': 'CreditScoreLens',
              'hash': tx_hash, 'contractAddress': lens, 'transaction': {'input': code, 'value': '0x0'}}],
              'receipts': [{'status': '0x1', 'transactionHash': tx_hash, 'contractAddress': lens}]}
    path = pathlib.Path(os.environ['FOUNDRY_BROADCAST']) / 'DeployCreditScoreLens.s.sol/1/run-latest.json'
    path.parent.mkdir(parents=True); path.write_text(json.dumps(record))
elif args[0] == 'verify-contract':
    assert args[args.index('--compilation-profile') + 1] == 'viair'
    assert args[args.index('--verifier') + 1] == 'etherscan'
    assert '--skip-is-verified-check' in args
    assert args[args.index('--delay') + 1] == '10'
    assert os.environ.get('ETHERSCAN_API_KEY') == 'test-api-key'
    print('Verified source.')
''')
            for executable in (root / 'bin').iterdir():
                executable.chmod(0o755)
            env = os.environ.copy()
            env.pop('ETHERSCAN_API_KEY', None)
            env.update(PATH=str(root / 'bin') + os.pathsep + env['PATH'], TEST_BRANCH=branch,
                       TEST_LOG=str(root / 'commands.log'), ETH_KEYSTORE_ACCOUNT='__must_not_unlock__')
            result = subprocess.run(['bash', str(root / 'script/deploy-credit-score-lens.sh'), *args],
                                    input=answer, text=True, capture_output=True, env=env)
            commands = (root / 'commands.log').read_text() if (root / 'commands.log').exists() else ''
            return result, commands

    def test_cancellation_stops_after_gas_preview_before_wallet_or_key(self):
        result, commands = self.invoke(answer='n\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('0.0001 ETH', result.stdout)
        self.assertNotIn('--broadcast', commands)
        self.assertNotIn('"config"', commands)

    def test_deploy_orders_fee_before_wallet_and_verifies_fresh_address(self):
        result, commands = self.invoke(answer='y\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index('0.0001 ETH'), result.stdout.index('Keystore password'))
        self.assertIn('Verified source.', result.stdout)
        self.assertIn('verify ' + LENS, result.stdout)
        self.assertNotIn('test-api-key', result.stdout + commands)
        self.assertNotIn('director.py', commands)
        self.assertIn('https://mainnet.gateway.tenderly.co', commands)

    def test_verify_retry_does_not_deploy_or_unlock(self):
        result, commands = self.invoke(('verify', LENS))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Verified source.', result.stdout)
        self.assertNotIn('--broadcast', commands)
        self.assertNotIn('--account', commands)

    def test_wrong_branch_or_changed_artifact_stops_before_wallet(self):
        for kwargs in ({'branch': 'feature'}, {'corrupt': True}):
            result, commands = self.invoke(answer='y\n', **kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('--broadcast', commands)


if __name__ == '__main__':
    unittest.main()
