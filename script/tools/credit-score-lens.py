#!/usr/bin/env python3
"""Simulate, deploy, check and publish verified source for CreditScoreLens."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = ROOT / "out/CreditScoreLens.sol/CreditScoreLens.json"
CONTRACT = "src/CreditScoreLens.sol:CreditScoreLens"
DEPLOY_SCRIPT = "script/DeployCreditScoreLens.s.sol"
CHECK_SCRIPT = "script/VerifyCreditScoreLens.s.sol"
RUNTIME_HASH = "0xb2477fe32da0dfde830387f29295c5ad83e3438a11ecfa8994d21a92d81e7058"


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise argparse.ArgumentTypeError("expected a nonzero 20-byte Ethereum address")
    return value


def run(args, extra_env=None):
    env = os.environ.copy()
    env.update(extra_env or {})
    subprocess.run(args, cwd=ROOT, env=env, check=True)


def build():
    run(["forge", "build", "src/CreditScoreLens.sol", DEPLOY_SCRIPT, CHECK_SCRIPT])
    validate_artifact()


def validate_artifact():
    artifact = json.loads(ARTIFACT.read_text())
    metadata = artifact["metadata"]
    settings = metadata["settings"]
    if (metadata["compiler"]["version"].split("+")[0] != "0.8.30"
            or not settings.get("viaIR") or settings["optimizer"] != {"enabled": True, "runs": 200}
            or settings["evmVersion"] != "cancun" or settings["metadata"]["bytecodeHash"] != "none"):
        raise ValueError("helper compiler settings differ from the reviewed build")
    runtime_hash = subprocess.check_output(
        ["cast", "keccak", artifact["deployedBytecode"]["object"]], cwd=ROOT, text=True).strip()
    if runtime_hash != RUNTIME_HASH:
        raise ValueError("helper bytecode differs from the reviewed build")


def explorer_ready(verifier):
    if verifier == "etherscan" and not os.environ.get("ETHERSCAN_API_KEY"):
        raise ValueError("set ETHERSCAN_API_KEY or select --verifier sourcify")


def check(helper, rpc):
    run(["forge", "script", CHECK_SCRIPT, "--rpc-url", rpc], {"LENS_ADDRESS": helper})


def publish_source(helper, rpc, verifier):
    run([
        "forge", "verify-contract", helper, CONTRACT, "--chain", "1", "--rpc-url", rpc,
        "--compilation-profile", "viair", "--verifier", verifier, "--watch",
    ])


def deployment_receipt(path, creation_code):
    """Accept only the fresh run's single successful zero-value helper CREATE."""
    data = json.loads(path.read_text())
    txs, receipts = data.get("transactions", []), data.get("receipts", [])
    if data.get("chain") != 1 or len(txs) != 1 or len(receipts) != 1 or data.get("pending"):
        raise ValueError("expected exactly one confirmed mainnet deployment; inspect the broadcast record")
    tx, receipt = txs[0], receipts[0]
    body = tx.get("transaction", {})
    value = body.get("value", "0x0")
    value = int(value, 0) if isinstance(value, str) else int(value)
    if (tx.get("transactionType") != "CREATE" or tx.get("contractName") != "CreditScoreLens"
            or body.get("input") != creation_code or value != 0):
        raise ValueError("broadcast transaction differs from the helper artifact")
    if receipt.get("status") not in (1, "0x1") or not tx.get("hash") or receipt.get("transactionHash") != tx["hash"]:
        raise ValueError("deployment receipt is missing, failed or belongs to another transaction")
    helper = address(receipt.get("contractAddress", ""))
    if helper.lower() != tx.get("contractAddress", "").lower():
        raise ValueError("deployment address differs between transaction and receipt")
    return helper, tx["hash"]


def execute(args):
    if args.command == "deploy":
        if args.ledger and not args.sender:
            raise ValueError("--ledger requires --sender with the Ledger account address")
        # The repository's configured gate remains authoritative; this tool does not waive it.
        run(["python3", "script/director.py", "check", "--gate", "deploy"])
        explorer_ready(args.verifier)
    elif args.command == "verify":
        explorer_ready(args.verifier)
    build()
    if args.command == "simulate":
        cmd = ["forge", "script", DEPLOY_SCRIPT, "--rpc-url", args.rpc_url]
        if args.sender:
            cmd += ["--sender", args.sender]
        if args.fork_block is not None:
            cmd += ["--fork-block-number", str(args.fork_block)]
        run(cmd)
        return
    if args.command in ("check", "verify"):
        check(args.address, args.rpc_url)
        if args.command == "verify":
            publish_source(args.address, args.rpc_url, args.verifier)
            check(args.address, args.rpc_url)
        return

    # Each broadcast has a new directory, so an old run-latest.json cannot supply the address.
    directory = ROOT / "broadcast"
    directory.mkdir(exist_ok=True)
    record_dir = Path(tempfile.mkdtemp(prefix="credit-score-lens-", dir=directory))
    print(f"Broadcast records: {record_dir}", flush=True)
    creation_code = json.loads(ARTIFACT.read_text())["bytecode"]["object"]
    cmd = ["forge", "script", DEPLOY_SCRIPT, "--rpc-url", args.rpc_url, "--broadcast", "--slow"]
    cmd += ["--ledger"] if args.ledger else ["--account", args.account]
    if args.sender:
        cmd += ["--sender", args.sender]
    run(cmd, {"FOUNDRY_BROADCAST": str(record_dir)})
    helper, tx_hash = deployment_receipt(record_dir / "DeployCreditScoreLens.s.sol/1/run-latest.json", creation_code)
    print(f"Deployed CreditScoreLens: {helper}\nDeployment transaction: {tx_hash}", flush=True)
    print(f"To retry verification without redeploying: python3 script/tools/credit-score-lens.py verify --address {helper}"
          f" --verifier {args.verifier}", flush=True)
    check(helper, args.rpc_url)
    publish_source(helper, args.rpc_url, args.verifier)
    check(helper, args.rpc_url)


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    for name in ("simulate", "deploy", "verify", "check"):
        command = commands.add_parser(name)
        command.add_argument("--rpc-url", default=os.environ.get("MAINNET_RPC_URL", "https://mainnet.gateway.tenderly.co"))
        if name in ("simulate", "deploy"):
            command.add_argument("--sender", type=address)
        if name == "simulate":
            command.add_argument("--fork-block", type=int)
        if name == "deploy":
            wallet = command.add_mutually_exclusive_group(required=True)
            wallet.add_argument("--ledger", action="store_true")
            wallet.add_argument("--account", help="Foundry encrypted keystore account name")
        if name in ("verify", "check"):
            command.add_argument("--address", required=True, type=address)
        if name in ("deploy", "verify"):
            command.add_argument("--verifier", choices=("etherscan", "sourcify"), default="etherscan")
    return cli


if __name__ == "__main__":
    try:
        execute(parser().parse_args())
    except (ValueError, argparse.ArgumentTypeError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as error:
        print(f"error: {Path(error.cmd[0]).name} exited with status {error.returncode}.", file=sys.stderr)
        print("If a deployment already succeeded, use verify with its address; do not redeploy.", file=sys.stderr)
        sys.exit(1)
