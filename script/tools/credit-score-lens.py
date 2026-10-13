#!/usr/bin/env python3
"""Simulate, deploy, check and publish verified source for CreditScoreLens."""
import argparse
from decimal import Decimal, DecimalException
import getpass
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
DEFAULT_SENDER = "0xCB43078C32423F5348Cab5885911C3B5faE217F9"
TENDERLY_RPC = "https://mainnet.gateway.tenderly.co"


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise argparse.ArgumentTypeError("expected a nonzero 20-byte Ethereum address")
    return value


def command_env(extra_env=None, wallet_free=False):
    env = os.environ.copy()
    if wallet_free:
        for name in ("ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_PASSWORD", "ETH_PRIVATE_KEY", "PRIVATE_KEY",
                     "TEMPO_ACCESS_KEY", "TURNKEY_API_PRIVATE_KEY", "AWS_KMS_KEY_ID", "GCP_KEY_NAME"):
            env.pop(name, None)
    env.update(extra_env or {})
    return env


def run(args, extra_env=None, wallet_free=False):
    if wallet_free:
        print(capture(args, extra_env, wallet_free=True), end="", flush=True)
        return
    subprocess.run(args, cwd=ROOT, env=command_env(extra_env, wallet_free), check=True)


def capture(args, extra_env=None, wallet_free=False):
    if wallet_free:
        # Foundry loads .env before parsing --root. An external cwd prevents signer settings
        # from being reintroduced by the project's .env after sanitizing the environment.
        with tempfile.TemporaryDirectory(prefix="credit-score-lens-read-") as directory:
            command = list(args)
            command[2] = str(ROOT / command[2])
            command += ["--root", str(ROOT)]
            return subprocess.check_output(command, cwd=directory, env=command_env(extra_env, True),
                                           text=True, stderr=subprocess.PIPE)
    return subprocess.check_output(args, cwd=ROOT, env=command_env(extra_env, wallet_free),
                                   text=True, stderr=subprocess.PIPE)


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
    if verifier != "etherscan":
        return {}
    key = os.environ.get("ETHERSCAN_API_KEY", "").strip()
    if not key:
        # Foundry resolves the project's .env and standard local/global configuration.
        config = json.loads(capture(["forge", "config", "--json"]))
        key = config.get("etherscan_api_key") or ""
        if not key:
            for name, entry in config.get("etherscan", {}).items():
                if entry.get("chain") in (1, "1", "mainnet") or (name == "mainnet" and not entry.get("chain")):
                    key = entry.get("key") or ""
                    break
    if not key or "${" in key:
        if not sys.stdin.isatty() or not sys.stderr.isatty():
            raise ValueError("set ETHERSCAN_API_KEY or run in a terminal for the private API-key prompt")
        key = getpass.getpass("Etherscan API key (hidden, used for this run only): ").strip()
    if not key:
        raise ValueError("Etherscan API key is required")
    return {"ETHERSCAN_API_KEY": key}


def fee_from_output(output):
    """Read Foundry's JSON stream, which includes traces before the fee estimate."""
    objects = []
    decoder = json.JSONDecoder()
    remaining = output.strip()
    while remaining:
        value, end = decoder.raw_decode(remaining)
        objects.append(value)
        remaining = remaining[end:].strip()
    quotes = [value for value in objects if isinstance(value, dict) and "estimated_total_gas_used" in value]
    if (len(quotes) != 1 or not all(isinstance(value, dict) for value in objects)
            or not any(value.get("success") is True for value in objects)
            or not any(value.get("status") == "success" for value in objects)):
        raise ValueError("deployment simulation did not return one successful fee estimate")
    quote = quotes[0]
    if quote.get("chain") != 1 or quote.get("token_symbol") != "ETH":
        raise ValueError("fee estimate must be for Ethereum mainnet")
    gas = int(quote["estimated_total_gas_used"])
    max_fee = Decimal(quote["estimated_max_fee_per_gas"]) * 10**9
    tip = Decimal(quote["estimated_max_priority_fee_per_gas"]) * 10**9
    if (gas <= 0 or not max_fee.is_finite() or not tip.is_finite()
            or max_fee <= 0 or tip < 0 or tip > max_fee
            or max_fee != int(max_fee) or tip != int(tip)):
        raise ValueError("invalid gas or fee estimate")
    return gas, int(max_fee), int(tip)


def estimate_fee(rpc, sender):
    # No --account, hardware-wallet flag or broadcast: fees are shown before any unlock prompt.
    with tempfile.TemporaryDirectory(prefix="credit-score-lens-estimate-") as directory:
        output = capture([
            "forge", "script", DEPLOY_SCRIPT, "--rpc-url", rpc, "--sender", sender,
            "--gas-estimate-multiplier", "130", "--json",
        ], {"FOUNDRY_BROADCAST": directory}, wallet_free=True)
    gas, max_fee, tip = fee_from_output(output)
    budget = Decimal(gas * max_fee) / 10**18
    print(f"Sender: {sender}\nGas budget: {gas:,} (includes Foundry's 30% buffer)", flush=True)
    print(f"Max fee: {Decimal(max_fee) / 10**9:f} gwei; priority fee: {Decimal(tip) / 10**9:f} gwei", flush=True)
    print(f"Estimated gas fee budget: {budget:f} ETH", flush=True)
    print("Actual fee depends on mined gas used and base fee. These fee settings will be reused for broadcast.", flush=True)
    return max_fee, tip


def check(helper, rpc):
    run(["forge", "script", CHECK_SCRIPT, "--rpc-url", rpc],
        {"LENS_ADDRESS": helper}, wallet_free=True)


def publish_source(helper, rpc, verifier, credentials):
    run([
        "forge", "verify-contract", helper, CONTRACT, "--chain", "1", "--rpc-url", rpc,
        "--compilation-profile", "viair", "--verifier", verifier, "--watch",
    ], credentials)


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
        if not args.sender:
            if args.account and args.account != "ripe0x":
                raise ValueError("a different --account requires its public --sender address")
            args.sender = DEFAULT_SENDER
        # The repository's configured gate remains authoritative; this tool does not waive it.
        run(["python3", "script/director.py", "check", "--gate", "deploy"])
    build()
    fees = None
    if args.command in ("estimate", "deploy"):
        fees = estimate_fee(args.rpc_url, args.sender)
        if args.command == "estimate":
            return
    if args.command == "simulate":
        cmd = ["forge", "script", DEPLOY_SCRIPT, "--rpc-url", args.rpc_url]
        if args.sender:
            cmd += ["--sender", args.sender]
        if args.fork_block is not None:
            cmd += ["--fork-block-number", str(args.fork_block)]
        run(cmd, wallet_free=True)
        return
    if args.command in ("check", "verify"):
        check(args.address, args.rpc_url)
        if args.command == "verify":
            credentials = explorer_ready(args.verifier)
            publish_source(args.address, args.rpc_url, args.verifier, credentials)
            check(args.address, args.rpc_url)
        return

    credentials = explorer_ready(args.verifier)
    wallet = "Ledger" if args.ledger else f"keystore {args.account or 'ripe0x'}"
    if input(f"Continue to unlock {wallet} and deploy with this fee budget? [y/N] ").strip().lower() != "y":
        print("Cancelled. No keystore unlocked or transaction sent.")
        return

    # Each broadcast has a new directory, so an old run-latest.json cannot supply the address.
    directory = ROOT / "broadcast"
    directory.mkdir(exist_ok=True)
    record_dir = Path(tempfile.mkdtemp(prefix="credit-score-lens-", dir=directory))
    print(f"Broadcast records: {record_dir}", flush=True)
    creation_code = json.loads(ARTIFACT.read_text())["bytecode"]["object"]
    cmd = ["forge", "script", DEPLOY_SCRIPT, "--rpc-url", args.rpc_url, "--broadcast", "--slow",
           "--gas-estimate-multiplier", "130", "--with-gas-price", str(fees[0]),
           "--priority-gas-price", str(fees[1])]
    cmd += ["--ledger"] if args.ledger else ["--account", args.account or "ripe0x"]
    if args.sender:
        cmd += ["--sender", args.sender]
    run(cmd, {"FOUNDRY_BROADCAST": str(record_dir)})
    helper, tx_hash = deployment_receipt(record_dir / "DeployCreditScoreLens.s.sol/1/run-latest.json", creation_code)
    print(f"Deployed CreditScoreLens: {helper}\nDeployment transaction: {tx_hash}", flush=True)
    print(f"To retry verification without redeploying: python3 script/tools/credit-score-lens.py verify --address {helper}"
          f" --verifier {args.verifier}", flush=True)
    check(helper, args.rpc_url)
    publish_source(helper, args.rpc_url, args.verifier, credentials)
    check(helper, args.rpc_url)


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    for name in ("simulate", "estimate", "deploy", "verify", "check"):
        command = commands.add_parser(name)
        command.add_argument("--rpc-url", default=os.environ.get("TENDERLY_RPC_URL") or TENDERLY_RPC)
        if name in ("simulate", "estimate", "deploy"):
            command.add_argument("--sender", type=address, default=None if name == "deploy" else DEFAULT_SENDER)
        if name == "simulate":
            command.add_argument("--fork-block", type=int)
        if name == "deploy":
            wallet = command.add_mutually_exclusive_group()
            wallet.add_argument("--ledger", action="store_true")
            wallet.add_argument("--account", help="Foundry encrypted keystore account name (default: ripe0x)")
        if name in ("verify", "check"):
            command.add_argument("--address", required=True, type=address)
        if name in ("deploy", "verify"):
            command.add_argument("--verifier", choices=("etherscan", "sourcify"), default="etherscan")
    return cli


if __name__ == "__main__":
    try:
        execute(parser().parse_args())
    except (ValueError, DecimalException, argparse.ArgumentTypeError, OSError, KeyError, EOFError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as error:
        print(f"error: {Path(error.cmd[0]).name} exited with status {error.returncode}.", file=sys.stderr)
        print("If a deployment already succeeded, use verify with its address; do not redeploy.", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        sys.exit(130)
