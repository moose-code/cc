"""Focused safety checks for the CreditScoreLens deployment driver."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("lens_tool", Path(__file__).parent / "tools/credit-score-lens.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

HELPER = "0x" + "12" * 20
TX_HASH = "0x" + "ab" * 32
CREATION = "0x60006000"
FEE = {"chain": 1, "token_symbol": "ETH", "estimated_total_gas_used": 484845,
       "estimated_max_fee_per_gas": "0.215137664", "estimated_max_priority_fee_per_gas": "0.001"}


def fee_output(quote=None):
    return "\n".join(json.dumps(value) for value in
                     ({"success": True}, quote or FEE, {"status": "success"}))


class CreditScoreLensToolTest(unittest.TestCase):
    def receipt(self):
        return {
            "chain": 1, "pending": [],
            "transactions": [{"transactionType": "CREATE", "contractName": "CreditScoreLens", "hash": TX_HASH,
                              "contractAddress": HELPER, "transaction": {"input": CREATION, "value": "0x0"}}],
            "receipts": [{"status": "0x1", "transactionHash": TX_HASH, "contractAddress": HELPER}],
        }

    def read_receipt(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run-latest.json"
            path.write_text(json.dumps(data))
            return tool.deployment_receipt(path, CREATION)

    def test_confirmed_receipt_is_bound_to_artifact_and_transaction(self):
        self.assertEqual(self.read_receipt(self.receipt()), (HELPER, TX_HASH))

    def test_failed_pending_foreign_or_mismatched_receipts_are_rejected(self):
        changes = [
            lambda d: d.update(chain=2),
            lambda d: d.update(pending=[TX_HASH]),
            lambda d: d["receipts"][0].update(status="0x0"),
            lambda d: d["receipts"][0].update(transactionHash="0x" + "cd" * 32),
            lambda d: d["receipts"][0].update(contractAddress="0x" + "34" * 20),
            lambda d: d["transactions"][0]["transaction"].update(input="0x6001"),
            lambda d: d["transactions"][0]["transaction"].update(value="0x1"),
            lambda d: d["transactions"].append(copy.deepcopy(d["transactions"][0])),
        ]
        for change in changes:
            with self.subTest(change=change):
                data = self.receipt()
                change(data)
                with self.assertRaises(ValueError):
                    self.read_receipt(data)

    def test_release_gate_failure_stops_before_build_wallet_or_broadcast(self):
        args = tool.parser().parse_args(["deploy"])
        with patch.object(tool, "run", side_effect=subprocess.CalledProcessError(1, ["python3"] )) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                tool.execute(args)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0], ["python3", "script/director.py", "check", "--gate", "deploy"])

    def test_simulation_has_no_wallet_or_broadcast_arguments(self):
        args = tool.parser().parse_args(["simulate", "--fork-block", "26158000"])
        with patch.object(tool, "run") as run, patch.object(tool, "validate_artifact"):
            tool.execute(args)
            command = run.call_args.args[0]
            self.assertIn("--fork-block-number", command)
            self.assertNotIn("--broadcast", command)
            self.assertNotIn("--account", command)
            self.assertNotIn("--ledger", command)

    def test_explicit_genesis_block_is_not_silently_replaced_with_latest(self):
        args = tool.parser().parse_args(["simulate", "--fork-block", "0"])
        with patch.object(tool, "run") as run, patch.object(tool, "validate_artifact"):
            tool.execute(args)
            command = run.call_args.args[0]
            self.assertEqual(command[command.index("--fork-block-number") + 1], "0")

    def test_verification_can_retry_without_deployment(self):
        args = tool.parser().parse_args(["verify", "--address", HELPER, "--verifier", "sourcify"])
        with patch.object(tool, "run") as run, patch.object(tool, "validate_artifact"):
            tool.execute(args)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertFalse(any("--broadcast" in command for command in commands))
            publish = next(command for command in commands if "verify-contract" in command)
            self.assertEqual(publish[publish.index("--compilation-profile") + 1], "viair")
            self.assertIn("--watch", publish)
            self.assertEqual(sum(command[:2] == ["forge", "script"] and tool.CHECK_SCRIPT in command
                                 for command in commands), 2)

    def test_etherscan_credentials_are_checked_before_deployment(self):
        args = tool.parser().parse_args(["deploy"])
        with patch.object(tool, "run") as run, patch.dict(tool.os.environ, {}, clear=True), \
                patch.object(tool, "build"), patch.object(tool, "estimate_fee", return_value=(2, 1)), \
                patch.object(tool, "capture", return_value='{}'), patch.object(tool.sys.stdin, "isatty", return_value=False):
            with self.assertRaisesRegex(ValueError, "ETHERSCAN_API_KEY"):
                tool.execute(args)
            self.assertEqual(run.call_count, 1)

    def test_ledger_requires_explicit_sender_before_any_command(self):
        args = tool.parser().parse_args(["deploy", "--ledger"])
        with patch.object(tool, "run") as run:
            with self.assertRaisesRegex(ValueError, "--sender"):
                tool.execute(args)
            run.assert_not_called()

    def test_changed_compiler_settings_or_bytecode_are_rejected(self):
        artifact = json.loads(tool.ARTIFACT.read_text())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact.json"
            wrong_settings = copy.deepcopy(artifact)
            wrong_settings["metadata"]["settings"]["metadata"]["bytecodeHash"] = "ipfs"
            path.write_text(json.dumps(wrong_settings))
            with patch.object(tool, "ARTIFACT", path):
                with self.assertRaisesRegex(ValueError, "compiler settings"):
                    tool.validate_artifact()
            path.write_text(json.dumps(artifact))
            with patch.object(tool, "ARTIFACT", path), patch.object(tool.subprocess, "check_output", return_value="0xwrong"):
                with self.assertRaisesRegex(ValueError, "bytecode differs"):
                    tool.validate_artifact()

    def test_tenderly_defaults_and_other_keystore_requires_sender(self):
        with patch.dict(tool.os.environ, {"MAINNET_RPC_URL": "https://different.example"}, clear=True):
            args = tool.parser().parse_args(["deploy"])
            self.assertEqual(args.rpc_url, tool.TENDERLY_RPC)
        args = tool.parser().parse_args(["deploy", "--account", "other"])
        with patch.object(tool, "run") as run:
            with self.assertRaisesRegex(ValueError, "public --sender"):
                tool.execute(args)
            run.assert_not_called()

    def test_foundry_json_fee_stream_and_exact_wei_conversion(self):
        self.assertEqual(tool.fee_from_output(fee_output()), (484845, 215137664, 1000000))
        for changes in ({"chain": 2}, {"estimated_total_gas_used": 0}, {"token_symbol": "USD"},
                        {"estimated_max_fee_per_gas": "-1"}, {"estimated_max_priority_fee_per_gas": "1"},
                        {"estimated_max_fee_per_gas": "NaN"}, {"estimated_max_fee_per_gas": "0.0000000001"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                tool.fee_from_output(fee_output(FEE | changes))
        for output in (fee_output() + json.dumps(FEE), '{}',
                       fee_output().replace('"success": true', '"success": false')):
            with self.subTest(output=output), self.assertRaises(ValueError):
                tool.fee_from_output(output)

    def test_estimate_shows_eth_budget_without_wallet_credentials_or_gate(self):
        args = tool.parser().parse_args(["estimate"])
        with patch.object(tool, "build"), patch.object(tool, "run") as run, \
                patch.object(tool, "capture", return_value=fee_output()) as capture, \
                patch.object(tool, "explorer_ready") as credentials, \
                patch("builtins.input") as confirm, patch("sys.stdout", new_callable=io.StringIO) as output:
            tool.execute(args)
            command = capture.call_args.args[0]
            self.assertNotIn("--account", command)
            self.assertNotIn("--ledger", command)
            self.assertNotIn("--broadcast", command)
            self.assertIn("0.00010430842070208 ETH", output.getvalue())
            run.assert_not_called()
            credentials.assert_not_called()
            confirm.assert_not_called()

    def test_failed_fee_estimate_stops_before_key_prompt_and_wallet(self):
        args = tool.parser().parse_args(["deploy"])
        with patch.object(tool, "build"), patch.object(tool, "run") as run, \
                patch.object(tool, "capture", return_value='{}'), patch.object(tool, "explorer_ready") as credentials:
            with self.assertRaises(ValueError):
                tool.execute(args)
            credentials.assert_not_called()
            self.assertEqual(run.call_count, 1)  # Only the release gate.

    def test_environment_and_foundry_keys_are_reused_without_prompt(self):
        with patch.dict(tool.os.environ, {"ETHERSCAN_API_KEY": "test-key"}, clear=True), \
                patch.object(tool, "capture") as capture, patch.object(tool.getpass, "getpass") as prompt:
            self.assertEqual(tool.explorer_ready("etherscan"), {"ETHERSCAN_API_KEY": "test-key"})
            capture.assert_not_called()
            prompt.assert_not_called()
        for config in ({"etherscan_api_key": "test-key"}, {"etherscan": {"mainnet": {"chain": 1, "key": "test-key"}}}):
            with patch.dict(tool.os.environ, {}, clear=True), patch.object(tool, "capture", return_value=json.dumps(config)), \
                    patch.object(tool.getpass, "getpass") as prompt:
                self.assertEqual(tool.explorer_ready("etherscan"), {"ETHERSCAN_API_KEY": "test-key"})
                prompt.assert_not_called()

    def test_missing_api_key_prompts_privately_and_is_not_persisted(self):
        with patch.dict(tool.os.environ, {}, clear=True), patch.object(tool, "capture", return_value='{}'), \
                patch.object(tool.sys.stdin, "isatty", return_value=True), \
                patch.object(tool.sys.stderr, "isatty", return_value=True), \
                patch.object(tool.getpass, "getpass", return_value="test-key") as prompt:
            self.assertEqual(tool.explorer_ready("etherscan"), {"ETHERSCAN_API_KEY": "test-key"})
            prompt.assert_called_once()
            self.assertNotIn("ETHERSCAN_API_KEY", tool.os.environ)

    def test_inherited_signer_settings_are_removed_from_fee_simulation(self):
        with patch.dict(tool.os.environ, {"ETH_KEYSTORE_ACCOUNT": "ripe0x", "ETH_PASSWORD": "private-file"}, clear=True), \
                patch.object(tool.subprocess, "check_output", return_value=fee_output()) as process, \
                patch("sys.stdout", new_callable=io.StringIO):
            tool.estimate_fee(tool.TENDERLY_RPC, tool.DEFAULT_SENDER)
            env = process.call_args.kwargs["env"]
            self.assertNotIn("ETH_KEYSTORE_ACCOUNT", env)
            self.assertNotIn("ETH_PASSWORD", env)
            self.assertNotEqual(Path(process.call_args.kwargs["cwd"]), tool.ROOT)
            self.assertIn("--root", process.call_args.args[0])

    def test_cancellation_never_opens_keystore(self):
        args = tool.parser().parse_args(["deploy", "--verifier", "sourcify"])
        with patch.object(tool, "build"), patch.object(tool, "run") as run, \
                patch.object(tool, "capture", return_value=fee_output()), \
                patch("builtins.input", return_value="n"), patch("sys.stdout", new_callable=io.StringIO) as output:
            tool.execute(args)
            self.assertIn("Estimated gas fee budget", output.getvalue())
            self.assertEqual(run.call_count, 1)

    def test_deploy_shows_fee_before_unlock_and_reuses_quoted_fees(self):
        args = tool.parser().parse_args(["deploy"])
        events = []
        with tempfile.TemporaryDirectory() as directory:
            def run(command, extra_env=None, wallet_free=False):
                if "--broadcast" in command:
                    events.append("wallet")
                    self.assertEqual(command[command.index("--account") + 1], "ripe0x")
                    self.assertEqual(command[command.index("--sender") + 1], tool.DEFAULT_SENDER)
                    self.assertEqual(command[command.index("--with-gas-price") + 1], "215137664")
                    self.assertEqual(command[command.index("--priority-gas-price") + 1], "1000000")
                if "verify-contract" in command:
                    self.assertNotIn("test-key", command)
                    self.assertEqual(extra_env, {"ETHERSCAN_API_KEY": "test-key"})

            def confirm(_):
                self.assertIn("Estimated gas fee budget", output.getvalue())
                events.append("confirmation")
                return "y"

            with patch.object(tool, "ROOT", Path(directory)), patch.object(tool, "build"), \
                    patch.object(tool, "run", side_effect=run), patch.object(tool, "capture", return_value=fee_output()), \
                    patch.dict(tool.os.environ, {"ETHERSCAN_API_KEY": "test-key"}, clear=True), \
                    patch.object(tool, "deployment_receipt", return_value=(HELPER, TX_HASH)), \
                    patch("builtins.input", side_effect=confirm), patch("sys.stdout", new_callable=io.StringIO) as output:
                tool.execute(args)
                self.assertEqual(events, ["confirmation", "wallet"])
                self.assertNotIn("test-key", output.getvalue())


if __name__ == "__main__":
    unittest.main()
