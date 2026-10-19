#!/usr/bin/env python3
"""Focused no-network checks for the mainnet transaction approval boundary."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mainnet_launch", ROOT / "script/mainnet-launch.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)
OWNER = launch.OWNER


class ApprovalTests(unittest.TestCase):
    def test_fee_ceiling_covers_the_observed_forge_fee_drift(self):
        # promise: a small base-fee move after preview does not reject a signed transaction before review.
        self.assertGreaterEqual(launch.fee_ceiling(122_000_000), 272_363_873)
        self.assertEqual(launch.fee_ceiling(300_000_000), 1_200_000_000)

    def test_rpc_identifies_the_client_to_the_send_relay(self):
        # promise: the approval gate's RPC client passes relay HTTP filtering before an approved send.
        with patch.object(launch.urllib.request, "urlopen", return_value=io.BytesIO(b'{"result":"0x1"}')) as opened:
            self.assertEqual(launch.rpc("https://rpc.mevblocker.io/fullprivacy", "eth_chainId", []), "0x1")
        self.assertEqual(opened.call_args.args[0].get_header("User-agent"), "cc-mainnet-launch/1.0")

    def test_optional_rpc_probe_returns_upstream_method_not_found(self):
        # promise: unsupported Forge probes keep the upstream JSON-RPC error without stopping the approval gate.
        response = b'{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}'
        handler = launch.GateHandler.__new__(launch.GateHandler)
        handler.gate = SimpleNamespace(read_url="https://read-rpc.example")
        with patch.object(launch.urllib.request, "urlopen", side_effect=lambda *_a, **_kw: io.BytesIO(response)):
            self.assertEqual(handler.forward({"jsonrpc": "2.0", "id": 42,
                                              "method": "anvil_nodeInfo", "params": []}),
                             {"jsonrpc": "2.0", "id": 42,
                              "error": {"code": -32601, "message": "method not found"}})
            with self.assertRaisesRegex(RuntimeError, "method not found"):
                launch.rpc("https://read-rpc.example", "eth_chainId", [])

    def test_local_gate_reports_the_expected_owner_without_unlocking_a_keystore(self):
        # promise: the shell can check the wrapper's expected owner before its signer-checking send gate.
        handler = launch.GateHandler.__new__(launch.GateHandler)
        handler.gate = SimpleNamespace(owner=OWNER)
        self.assertEqual(handler.forward({"jsonrpc": "2.0", "id": 7,
                                          "method": "cc_approvalGateOwner", "params": []}),
                         {"jsonrpc": "2.0", "id": 7, "result": OWNER})

    def test_launch_config_display_uses_the_selected_file(self):
        # promise: the operator sees every value from the selected launch config before approval.
        with TemporaryDirectory() as temp:
            path = Path(temp) / "launch.json"
            expected = {"owner": OWNER, "rateStart": "4650000000000000", "stack": {"poolFee": 8388608}}
            path.write_text(json.dumps(expected))
            output = io.StringIO()
            with redirect_stdout(output):
                launch.print_launch_config(path)
            self.assertIn(str(path), output.getvalue())
            for item in (f"owner: \"{OWNER}\"", "rateStart: \"4650000000000000\"",
                         "stack.poolFee: 8388608"):
                self.assertIn(item, output.getvalue())

    def test_live_output_shows_password_prompt_without_forge_dump(self):
        # promise: the operator sees the password and progress prompts while successful Forge logs stay out of the terminal.
        script = ("import sys; print('deploy.sh: start block 123, signer nonce 4'); "
                  "print('deploy.sh: preflight'); print('noisy check row'); "
                  "print('deploy.sh: deploy'); "
                  "sys.stdout.write('Enter keystore password:'); sys.stdout.flush(); "
                  "print('deploy.sh: postflight'); "
                  "print('deploy.sh: wrote deployments/1.json (core 0xabc, deploy block 124)'); "
                  "print('deploy.sh: verify src/Core.sol:Core at 0xabc'); print('deploy.sh: done')")
        output = io.StringIO()
        with redirect_stdout(output):
            launch.run_live([sys.executable, "-c", script], env={**os.environ, "KEYSTORE_ACCOUNT": "ripe0x"})
        shown = output.getvalue()
        self.assertIn("Checking the live chain", shown)
        self.assertIn("Enter the password for ripe0x", shown)
        self.assertIn("Checking deployed contracts", shown)
        self.assertIn("Recovery anchor: start block 123, signer nonce 4", shown)
        self.assertIn("Deployment record: deployments/1.json", shown)
        self.assertIn("Verifying src/Core.sol:Core", shown)
        self.assertNotIn("noisy check row", shown)

    def test_live_failure_shows_the_actual_diagnostic(self):
        # promise: hiding successful Forge logs does not hide a failed deployment's diagnostic.
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaisesRegex(RuntimeError, "exited 2"):
            launch.run_live([sys.executable, "-c", "import sys; print('failed step'); sys.exit(2)"],
                            env={**os.environ, "KEYSTORE_ACCOUNT": "ripe0x"})
        self.assertIn("failed step", errors.getvalue())

    def setUp(self):
        self.planned = {
            "transactionType": "CREATE2", "contractName": "CoreLib",
            "contractAddress": "0x" + "b" * 40,
            "transaction": {"to": "0x" + "c" * 40, "input": "0x1234", "value": "0x0", "gas": "0x10000"},
        }
        tx = self.planned["transaction"]
        self.signed = {
            "type": "0x2", "chainId": "0x1", "signer": OWNER, "nonce": "0x1",
            "to": tx["to"], "input": tx["input"], "value": "0x0",
            "gas": tx["gas"], "maxFeePerGas": "0x64", "maxPriorityFeePerGas": "0x1",
        }

    def test_adapter_steps_name_the_approved_adapter(self):
        # promise: each adapter approval names the module whose approved address it enables.
        first = {"contractName": "SeaportBasicAdapter", "contractAddress": "0x" + "1" * 40,
                 "transactionType": "CREATE2"}
        second = {"contractName": "CreditStrategyAdapter", "contractAddress": "0x" + "2" * 40,
                  "transactionType": "CREATE2"}
        for address, name in ((first["contractAddress"], "Seaport"),
                              (second["contractAddress"], "CreditStrategy")):
            approval = {"function": "addAdapter(address)", "arguments": [address]}
            self.assertIn(name, launch.describe_transaction(approval, [first, second]))

    def test_changed_signed_action_is_rejected(self):
        # promise: a signed transaction with extra authority or altered calldata cannot pass the approved preview.
        for changed in ({"input": "0x00"}, {"chainId": "0x2"}, {"type": "0x4"},
                        {"authorizationList": [{}]}, {"maxFeePerGas": "0x1000"}):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                launch.check_transaction({**self.signed, **changed}, self.planned, OWNER, 1, 100)

    def test_decline_never_forwards_and_approval_forwards_once(self):
        # promise: only an exact typed SEND response forwards a matching raw transaction to the private RPC.
        sent = []

        def fake_rpc(_url, method, params):
            if method == "eth_getTransactionCount":
                return "0x1"
            if method == "eth_getCode":
                return "0x6000" if params[0].lower() == self.signed["to"].lower() else "0x"
            if method == "eth_sendRawTransaction":
                sent.append(params[0])
                return "0x" + "a" * 64
            raise AssertionError(method)

        gate = launch.ApprovalGate("read-rpc", "private-rpc", [self.planned], 100, "0x" + "b" * 40)
        with patch.object(launch, "rpc", side_effect=fake_rpc), patch.object(launch, "decode", return_value=self.signed), \
             patch.object(launch, "run", return_value=SimpleNamespace(stdout="0x" + "a" * 64)):
            with patch("builtins.input", return_value="no"), self.assertRaises(RuntimeError):
                gate.send("0xraw")
            self.assertEqual(sent, [])
            with patch("builtins.input", return_value="SEND 1"):
                gate.send("0xraw")
            self.assertEqual(sent, ["0xraw"])
            self.assertEqual(gate.index, 1)
            self.assertEqual(gate.send("0xraw"), "0x" + "a" * 64)
            self.assertEqual(sent, ["0xraw"])
            self.assertEqual(gate.index, 1)
            with self.assertRaisesRegex(RuntimeError, "unplanned transaction"):
                gate.send("0xother")

    def test_record_recovery_detects_launched_coin(self):
        # promise: no-send recovery chooses the live-coin postflight after a launch lands.
        coin = "0x" + "d" * 40
        def fake_rpc(_url, method, params):
            if method == "eth_call":
                self.assertEqual(params[0]["data"], "0xa54a72b7")
                return "0x" + "0" * 24 + coin[2:]
            if method == "eth_getCode":
                self.assertEqual(params[0], coin)
                return "0x6000"
            raise AssertionError(method)
        with patch.object(launch, "rpc", side_effect=fake_rpc):
            self.assertTrue(launch.coin_is_live("read-rpc", "0x" + "a" * 40))

    def test_lost_send_response_reconciles_the_exact_hash(self):
        # promise: a lost relay response can confirm the same signed transaction without another send.
        digest = "0x" + "a" * 64
        sent = []

        def fake_rpc(_url, method, params):
            if method == "eth_getTransactionCount":
                return "0x1"
            if method == "eth_getCode":
                return "0x6000" if params[0].lower() == self.signed["to"].lower() else "0x"
            if method == "eth_sendRawTransaction":
                sent.append(params[0])
                raise RuntimeError("relay response lost")
            if method == "eth_getTransactionByHash":
                self.assertEqual(params, [digest])
                return {"hash": digest}
            raise AssertionError(method)

        gate = launch.ApprovalGate("read-rpc", "send-rpc", [self.planned], 100, "0x" + "b" * 40)
        with patch.object(launch, "rpc", side_effect=fake_rpc), patch.object(launch, "decode", return_value=self.signed), \
             patch.object(launch, "run", return_value=SimpleNamespace(stdout=digest)), \
             patch("builtins.input", return_value="SEND 1"):
            self.assertEqual(gate.send("0xraw"), digest)
            self.assertEqual(gate.send("0xraw"), digest)
        self.assertEqual(sent, ["0xraw"])

    def test_local_rehearsal_rejects_a_non_loopback_rpc(self):
        # promise: rehearsal mode cannot route a signed transaction to a public or mainnet RPC.
        values = {
            "KEYSTORE_ACCOUNT": "test",
            "REHEARSAL_DEPLOYER": "0x" + "a" * 40,
            "LAUNCH_CONFIG": "script/config/rehearsal.json",
            "RECORD_FILE": "/private/tmp/rehearsal-record.json",
            "CONFIG_LOCK_BACKUP": "/private/tmp/rehearsal-lock.json",
            "CONFIG_LOCK_DIR": str(ROOT / "broadcast/config-locks/rehearsal"),
        }
        for unsafe_url in ("https://gateway.tenderly.co/public/mainnet",
                           "http://127.0.0.1:8600@" + "public-rpc.example",
                           "http://127.0.0.1:8600/path"):
            with self.subTest(url=unsafe_url), patch.dict(os.environ, {**values, "RPC_URL": unsafe_url}, clear=True), \
                 patch.object(sys, "argv", ["mainnet-launch.py", "--local-rehearsal", "--preview"]), \
                 patch.object(launch, "run") as run, self.assertRaises(SystemExit):
                launch.main()
            run.assert_not_called()

    def test_rehearsal_gate_checks_the_test_signer(self):
        # promise: rehearsal reuses the signed-action gate with its configured test signer.
        test_owner = "0x" + "a" * 40
        gate = launch.ApprovalGate("read-rpc", "send-rpc", [self.planned], 100,
                                   "0x" + "b" * 40, test_owner)
        self.assertEqual(gate.owner, test_owner)
        with self.assertRaisesRegex(RuntimeError, "signer"):
            launch.check_transaction(self.signed, self.planned, gate.owner, 1, 100)
        launch.check_transaction({**self.signed, "signer": test_owner}, self.planned,
                                 gate.owner, 1, 100)


if __name__ == "__main__":
    unittest.main()
