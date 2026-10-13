"""Focused safety checks for the CreditScoreLens deployment driver."""
import copy
import importlib.util
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
        args = tool.parser().parse_args(["deploy", "--account", "owner"])
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
        args = tool.parser().parse_args(["deploy", "--account", "owner"])
        with patch.object(tool, "run") as run, patch.dict(tool.os.environ, {}, clear=True):
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


if __name__ == "__main__":
    unittest.main()
