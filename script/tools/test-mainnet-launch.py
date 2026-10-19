#!/usr/bin/env python3
"""Focused no-network checks for the mainnet transaction approval boundary."""

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mainnet_launch", ROOT / "script/mainnet-launch.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)
OWNER = launch.OWNER


class ApprovalTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
