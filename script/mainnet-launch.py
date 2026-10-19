#!/usr/bin/env python3
"""Clean, preview, price, and confirm the existing mainnet deploy path."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent.parent
MAIN_REPO = Path("/Users/dd/CascadeProjects/cc/cc")
OWNER = "0xcb43078c32423f5348cab5885911c3b5fae217f9"


def run(args, *, env=None, capture=False, input_text=None):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                            input=input_text,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None)
    if result.returncode:
        if capture and result.stdout:
            print(redact(result.stdout), file=sys.stderr)
        raise RuntimeError(f"{args[0]} exited {result.returncode}")
    return result


def redact(output):
    for name in ("RPC_URL", "PRIVATE_RPC", "ETHERSCAN_API_KEY"):
        value = os.environ.get(name)
        if value:
            output = output.replace(value, "[redacted]")
    return output


def number(value):
    return int(value, 0) if isinstance(value, str) and value.startswith("0x") else int(value or 0)


def print_launch_config(path):
    config = json.loads(path.read_text())
    print(f"\nLaunch config ({path}):", flush=True)
    print(json.dumps(config, indent=2, sort_keys=True), flush=True)


def rpc(url, method, params, *, preserve_response=False):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, payload, {"Content-Type": "application/json",
                                                "User-Agent": "cc-mainnet-launch/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            data = json.load(response)
    except (urllib.error.URLError, TimeoutError) as error:
        raise RuntimeError(f"RPC {method} transport failed") from error
    if "error" in data and not preserve_response:
        raise RuntimeError(f"RPC {method} failed: {redact(data['error'].get('message', 'unknown error'))}")
    return data if preserve_response else data["result"]


def coin_is_live(read_url, core):
    result = rpc(read_url, "eth_call", [{"to": core, "data": "0xa54a72b7"}, "latest"])
    if not isinstance(result, str) or len(result) != 66:
        raise RuntimeError("Core COIN() did not return an address")
    coin = "0x" + result[-40:]
    return rpc(read_url, "eth_getCode", [coin, "latest"]) != "0x"


def decode(raw):
    result = run(["cast", "decode-transaction", "--json"], capture=True, input_text=raw)
    envelope = json.loads(result.stdout)
    if not envelope.get("success"):
        raise RuntimeError("signed transaction decode failed")
    return json.loads(envelope["data"])


def check_transaction(tx, expected, owner, nonce, fee_cap):
    planned = expected["transaction"]
    equal = lambda a, b: (a or "").lower() == (b or "").lower()
    if number(tx.get("type", -1)) != 2 or tx.get("authorizationList") or tx.get("blobVersionedHashes"):
        raise RuntimeError("only an ordinary EIP-1559 transaction without authorizations or blobs is approved")
    if number(tx["chainId"]) != 1 or not equal(tx["signer"], owner):
        raise RuntimeError("signed chain or signer differs from the approved plan")
    if number(tx["nonce"]) != nonce:
        raise RuntimeError(f"signed nonce {number(tx['nonce'])} differs from live nonce {nonce}")
    if not equal(tx.get("to"), planned.get("to")) or not equal(tx["input"], planned["input"]):
        raise RuntimeError("signed target or calldata differs from the dry run")
    if number(tx["value"]) != number(planned.get("value")):
        raise RuntimeError("signed ETH value differs from the dry run")
    if number(tx["gas"]) > number(planned["gas"]) * 3 // 2:
        raise RuntimeError("signed gas limit exceeds 150% of the dry-run limit")
    signed_fee = number(tx.get("maxFeePerGas", tx.get("gasPrice", 0)))
    if signed_fee > fee_cap or number(tx.get("maxPriorityFeePerGas")) > signed_fee:
        raise RuntimeError("signed fee cap exceeds the approved pre-signing ceiling")
    return signed_fee


class ApprovalGate:
    def __init__(self, read_url, send_url, transactions, fee_cap, expected_coin, owner=OWNER):
        self.read_url = read_url
        self.send_url = send_url
        self.transactions = transactions
        self.fee_cap = fee_cap
        self.expected_coin = expected_coin
        self.owner = owner.lower()
        self.index = 0
        self.previous_hash = None
        self.previous_raw = None
        self.lock = threading.Lock()

    def send(self, raw):
        with self.lock:
            if raw == self.previous_raw:
                print(f"Repeated delivery of {self.previous_hash}; returning its existing hash.", flush=True)
                return self.previous_hash
            if self.index >= len(self.transactions):
                raise RuntimeError("unplanned transaction after the dry-run manifest")
            planned = self.transactions[self.index]
            tx = decode(raw)
            nonce = number(rpc(self.read_url, "eth_getTransactionCount", [self.owner, "pending"]))
            signed_fee = check_transaction(tx, planned, self.owner, nonce, self.fee_cap)
            if self.previous_hash:
                receipt = rpc(self.read_url, "eth_getTransactionReceipt", [self.previous_hash])
                if not receipt or number(receipt["status"]) != 1:
                    raise RuntimeError("the previous receipt is missing or failed; stop and reconcile")
                self.check_previous_state(self.transactions[self.index - 1])
                print(f"Previous receipt {self.previous_hash}: status 1, gas used {number(receipt['gasUsed']):,}; expected state confirmed.", flush=True)
            target = tx.get("to")
            code = rpc(self.read_url, "eth_getCode", [target, "latest"])
            created = planned.get("contractAddress") if planned.get("transactionType") == "CREATE2" else None
            if created:
                if code == "0x":
                    raise RuntimeError(f"CREATE2 deployer {target} has no code")
                if rpc(self.read_url, "eth_getCode", [created, "latest"]) != "0x":
                    raise RuntimeError(f"planned creation address {created} already has code")
            elif code == "0x":
                raise RuntimeError(f"call target {target} has no code")
            if (planned.get("function") or "").startswith("deployToken"):
                factory_owner = rpc(self.read_url, "eth_call", [{"to": target, "data": "0x8da5cb5b"}, "latest"])
                if "0x" + factory_owner[-40:].lower() != self.owner:
                    raise RuntimeError("factory owner changed before coin launch")
            label = planned.get("contractName") or "Artcoin V2 factory"
            function = planned.get("function") or ("CREATE2 deploy" if created else "contract call")
            print(f"\nTransaction {self.index + 1}/{len(self.transactions)}: {label} {function}", flush=True)
            print(f"Chain 1; signer {self.owner}; nonce {nonce}; target {target}; value {number(tx['value'])} wei", flush=True)
            print(f"Target code: {len(code[2:]) // 2} bytes; predicted creation: {created or 'none'}", flush=True)
            print(f"Gas limit {number(tx['gas']):,}; max fee {signed_fee / 1e9:.3f} gwei; calldata {len(tx['input'][2:]) // 2:,} bytes", flush=True)
            consequences = {
                "CoreLib": "Deploys the pricing and accounting library Core will call.",
                "CoreOpsLib": "Deploys the operations library Core will call.",
                "Core": "Deploys the Core that holds and routes system assets.",
                "ControllerV1": "Deploys the Credit and Statement pricing controller.",
                "SeaportBasicAdapter": "Deploys the Seaport order adapter.",
                "CreditStrategyAdapter": "Deploys the CreditStrategy listing adapter.",
                "LogoCoinRenderer": "Deploys the animated SVG coin metadata renderer.",
                "setCore(address)": "Binds the renderer to this Core.",
                "setController(address)": "Makes Core use the new pricing controller.",
                "addAdapter(address)": "Allows Core to use this listing adapter.",
                "deployToken": "Creates the CC coin and launches its pool through Artcoin V2.",
            }
            consequence = consequences.get(label) if created else consequences.get(function.split("(")[0] if function.startswith("deployToken") else function)
            print(f"Consequence: {consequence or function}", flush=True)
            args = planned.get("arguments")
            if args:
                print("Decoded arguments:", json.dumps(args, indent=2), flush=True)
            if input(f"Type SEND {self.index + 1} to broadcast this transaction: ") != f"SEND {self.index + 1}":
                raise RuntimeError("operator declined this transaction")
            digest = run(["cast", "keccak"], capture=True, input_text=raw).stdout.strip()
            try:
                result = rpc(self.send_url, "eth_sendRawTransaction", [raw])
            except RuntimeError as error:
                try:
                    seen = rpc(self.read_url, "eth_getTransactionByHash", [digest])
                except RuntimeError as lookup_error:
                    raise RuntimeError(f"send result uncertain for {digest}; reconcile before continuing") from lookup_error
                if not seen or seen.get("hash", "").lower() != digest.lower():
                    raise RuntimeError(f"send result uncertain for {digest}; reconcile before continuing") from error
                result = digest
            if result.lower() != digest.lower():
                raise RuntimeError("relay returned an unexpected transaction hash; reconcile before continuing")
            self.previous_hash = result
            self.previous_raw = raw
            self.index += 1
            print(f"Sent {result}. Forge --slow waits for the receipt before the next step.", flush=True)
            return result

    def check_previous_state(self, planned):
        created = planned.get("contractAddress") if planned.get("transactionType") == "CREATE2" else None
        if created:
            if rpc(self.read_url, "eth_getCode", [created, "latest"]) == "0x":
                raise RuntimeError(f"deployed contract {created} has no code after its receipt")
            return
        tx = planned["transaction"]
        target = tx["to"]
        function = planned.get("function") or ""
        arguments = planned.get("arguments") or []
        if function == "setCore(address)":
            result = rpc(self.read_url, "eth_call", [{"to": target, "data": "0xf2f4eb26"}, "latest"])
        elif function == "setController(address)":
            result = rpc(self.read_url, "eth_call", [{"to": target, "data": "0xf77c4791"}, "latest"])
        elif function == "addAdapter(address)":
            data = "0xf2c70e80" + arguments[0][2:].lower().rjust(64, "0")
            result = rpc(self.read_url, "eth_call", [{"to": target, "data": data}, "latest"])
            if number(result) != 1:
                raise RuntimeError("Core did not allow the adapter after its receipt")
            return
        elif function.startswith("deployToken"):
            if rpc(self.read_url, "eth_getCode", [self.expected_coin, "latest"]) == "0x":
                raise RuntimeError("CC coin has no code after launch receipt")
            return
        else:
            raise RuntimeError(f"no post-state check for {function}")
        if "0x" + result[-40:].lower() != arguments[0].lower():
            raise RuntimeError(f"{function} did not set the approved address")


class GateHandler(BaseHTTPRequestHandler):
    gate = None

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 4_000_000:
                raise RuntimeError("oversized RPC request")
            body = json.loads(self.rfile.read(length))
            if isinstance(body, list):
                if any(item.get("method", "").startswith("eth_send") for item in body):
                    raise RuntimeError("batched sends are not permitted")
                result = [self.forward(item) for item in body]
            else:
                result = self.forward(body)
            encoded = json.dumps(result).encode()
        except Exception as error:
            request_id = body.get("id") if isinstance(locals().get("body"), dict) else None
            print(f"Approval gate stopped: {error}", file=sys.stderr, flush=True)
            encoded = json.dumps({"jsonrpc": "2.0", "id": request_id,
                                  "error": {"code": -32000, "message": str(error)}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def forward(self, request):
        method = request.get("method", "")
        if method == "eth_sendRawTransaction":
            result = self.gate.send(request["params"][0])
        elif method.startswith("eth_send") or method.startswith("personal_"):
            raise RuntimeError(f"unapproved signing method {method}")
        else:
            upstream = rpc(self.gate.read_url, method, request.get("params", []), preserve_response=True)
            key = "error" if "error" in upstream else "result"
            return {"jsonrpc": "2.0", "id": request.get("id"), key: upstream[key]}
        return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true", help="clean, simulate, and price without signing or sending")
    parser.add_argument("--local-rehearsal", action="store_true", help="use a loopback chain-id-1 fork and rehearsal signer")
    parser.add_argument("--resume-core", help="Core address from an interrupted deployment")
    parser.add_argument("--from-block", type=int, help="start block printed by the interrupted deployment")
    parser.add_argument("--launch-only", action="store_true", help="launch the coin from a deferred deployment record")
    parser.add_argument("--record-only", action="store_true", help="finish record and verification after all deferred transactions landed")
    args = parser.parse_args()
    if bool(args.resume_core) != (args.from_block is not None) or (args.launch_only and args.resume_core) or (args.record_only and (args.launch_only or args.preview or not args.resume_core)):
        parser.error("use paired --resume-core/--from-block; --record-only cannot combine with --preview or --launch-only")
    if args.local_rehearsal and args.record_only:
        parser.error("record-only recovery uses the mainnet profile; local rehearsal tests signed deployment and launch")
    invoked_from = Path.cwd().resolve()
    os.chdir(ROOT)
    if args.local_rehearsal:
        needed = ("RPC_URL", "KEYSTORE_ACCOUNT", "REHEARSAL_DEPLOYER", "LAUNCH_CONFIG",
                  "RECORD_FILE", "CONFIG_LOCK_DIR", "CONFIG_LOCK_BACKUP")
    else:
        needed = ("RPC_URL", "KEYSTORE_ACCOUNT") if args.preview else (
            "RPC_URL", "PRIVATE_RPC", "KEYSTORE_ACCOUNT", "CONFIG_LOCK_BACKUP", "ETHERSCAN_API_KEY")
    missing = [name for name in needed if not os.environ.get(name)]
    if missing:
        parser.error("set " + ", ".join(missing) + " in the shell; keep secrets out of files and commands")
    if not args.local_rehearsal:
        if ROOT.resolve() != MAIN_REPO.resolve() or invoked_from != ROOT.resolve():
            parser.error(f"run from the primary repository directory {MAIN_REPO}")
        if run(["git", "branch", "--show-current"], capture=True).stdout.strip() != "main":
            parser.error("mainnet preview, recovery and broadcast require the main branch")
    config_path = Path(os.environ.get("LAUNCH_CONFIG") or "script/config/mainnet.json")
    if not config_path.is_absolute():
        config_path = ROOT / config_path
    config_path = config_path.resolve()
    if not config_path.is_file():
        parser.error(f"launch config is missing: {config_path}")
    if args.local_rehearsal:
        parsed = urlsplit(os.environ["RPC_URL"])
        if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port
                or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment):
            parser.error("local rehearsal requires a plain loopback HTTP RPC URL with an explicit port")
        owner = os.environ["REHEARSAL_DEPLOYER"].lower()
        if not re.fullmatch(r"0x[0-9a-f]{40}", owner) or owner == OWNER:
            parser.error("REHEARSAL_DEPLOYER must be a distinct test signer address")
        for name in ("RECORD_FILE", "CONFIG_LOCK_BACKUP"):
            supplied = Path(os.environ[name])
            path = supplied.resolve()
            if not supplied.is_absolute() or path == ROOT or ROOT in path.parents:
                parser.error(f"{name} must be an absolute path outside the repository")
        lock_dir = Path(os.environ["CONFIG_LOCK_DIR"])
        if not lock_dir.is_absolute() or ROOT / "broadcast" not in lock_dir.resolve().parents:
            parser.error("CONFIG_LOCK_DIR must be an absolute path under this checkout's broadcast directory")
        env_name = "rehearsal"
    else:
        owner = OWNER
        env_name = "mainnet"
    if os.environ.get("PASSWORD_FILE"):
        parser.error("unset PASSWORD_FILE; Foundry will prompt for the keystore password in this terminal")
    if not sys.stdin.isatty() and not args.preview:
        parser.error("broadcast requires an interactive terminal for individual approvals")
    env = dict(os.environ, TERMINAL_KEYSTORE="1", PASSWORD_FILE="", DRY_RUN="1",
               LAUNCH_CONFIG=str(config_path))
    if args.local_rehearsal:
        env.update(CHAIN_ID="1", REHEARSAL_SKIP_GIT="1")
    if args.resume_core:
        env.update(RESUME="record" if args.record_only else "state", CORE=args.resume_core,
                   FROM_BLOCK=str(args.from_block), DEFER_LAUNCH="1")
    elif args.launch_only:
        env.update(LAUNCH_ONLY="1", DEFER_LAUNCH="0")
    else:
        env.pop("RESUME", None)
        env.pop("LAUNCH_ONLY", None)
        env["DEFER_LAUNCH"] = "1"
    manifest = ROOT / f"broadcast/{'Resume' if args.resume_core or args.launch_only else 'Deploy'}.s.sol/1/dry-run/run-latest.json"
    print("Cleaning Foundry output and compiling the exact deployment path...", flush=True)
    run(["forge", "clean"])
    if args.record_only:
        backup = Path(env["CONFIG_LOCK_BACKUP"])
        if not backup.is_file():
            raise RuntimeError("durable config lock backup is missing; reconcile before record recovery")
        locked_hash = json.loads(backup.read_text())["configHash"]
        if not re.fullmatch(r"0x[0-9a-fA-F]{64}", locked_hash):
            raise RuntimeError("durable config lock has no valid config hash")
        print_launch_config(config_path)
        print("No transaction will be sent. This checks the completed deferred Core, writes its record and verifies contracts.")
        print(f"Original config hash: {locked_hash}")
        if input("Type RECORD to continue without a broadcast: ") != "RECORD":
            raise RuntimeError("record recovery was not approved")
        deferred = not coin_is_live(env["RPC_URL"], args.resume_core)
        print(f"Recovery state: coin {'unlaunched' if deferred else 'launched'}; postflight will check this state.")
        run(["script/deploy.sh", env_name], env=dict(env, DRY_RUN="0", CONFIG_HASH=locked_hash,
                                                   DEFER_LAUNCH="1" if deferred else "0"))
        return
    previous_manifest_time = manifest.stat().st_mtime_ns if manifest.exists() else 0
    preview = run(["script/deploy.sh", env_name], env=env, capture=True)
    print(redact(preview.stdout), flush=True)
    hashes = re.findall(r"deploy\.sh: CONFIG_HASH=(0x[0-9a-fA-F]{64})", preview.stdout)
    if len(hashes) != 1 or not manifest.is_file() or manifest.stat().st_mtime_ns <= previous_manifest_time:
        raise RuntimeError("the dry run did not produce one config hash and transaction manifest")
    transactions = json.loads(manifest.read_text())["transactions"]
    if not (1 <= len(transactions) <= 11) or (not args.resume_core and len(transactions) != (1 if args.launch_only else 11)):
        raise RuntimeError(f"unexpected transaction count in dry run: {len(transactions)}")
    coin_rows = re.findall(r"^[ \t]*coin(?: \(predicted, launch deferred\))? (0x[0-9a-fA-F]{40})", preview.stdout, re.MULTILINE)
    if len(coin_rows) != 1:
        raise RuntimeError("dry run did not print the predicted coin address")
    gas_limit = sum(number(item["transaction"]["gas"]) for item in transactions)
    gas_ceiling = sum(number(item["transaction"]["gas"]) * 3 // 2 for item in transactions)
    gas_price = number(run(["cast", "gas-price", "--rpc-url", env["RPC_URL"]], capture=True).stdout.strip())
    fee_cap = gas_price * 2
    value = sum(number(item["transaction"].get("value")) for item in transactions)
    balance = number(run(["cast", "balance", owner, "--rpc-url", env["RPC_URL"]], capture=True).stdout.strip().split()[0])
    print(f"\n{len(transactions)} planned transactions; summed dry-run gas limits {gas_limit:,}; maximum accepted signed limits {gas_ceiling:,}.")
    print(f"Current gas price {gas_price / 1e9:.3f} gwei; approved per-gas ceiling {fee_cap / 1e9:.3f} gwei.")
    print(f"Maximum accepted gas cost at that ceiling: {gas_ceiling * fee_cap / 1e18:.6f} ETH; transaction value {value / 1e18:.6f} ETH; signer balance {balance / 1e18:.6f} ETH.")
    for index, item in enumerate(transactions, 1):
        tx = item["transaction"]
        print(f"{index:2}. {item.get('contractName') or 'Artcoin V2 factory'} {item.get('function') or 'CREATE2 deploy'}: gas limit {number(tx['gas']):,}, value {number(tx.get('value'))} wei")
    print_launch_config(config_path)
    print(f"Config hash for review: {hashes[0]}")
    if args.preview:
        print("Preview complete. No password was requested and no transaction was sent.")
        return
    if balance < gas_ceiling * fee_cap + value:
        raise RuntimeError("signer ETH balance is below the displayed worst-case gas plus transaction value")
    send_url = env["RPC_URL"] if args.local_rehearsal else env["PRIVATE_RPC"]
    if number(run(["cast", "chain-id", "--rpc-url", send_url], capture=True).stdout.strip()) != 1:
        raise RuntimeError("broadcast endpoint is not Ethereum chain ID 1")
    if run(["git", "branch", "--show-current"], capture=True).stdout.strip() != "main":
        raise RuntimeError("broadcast requires the main branch")
    if run(["git", "status", "--porcelain"], capture=True).stdout.strip():
        raise RuntimeError("broadcast requires a clean checkout")
    if not args.local_rehearsal:
        run(["script/tools/check-freeze.sh"])
    if input("Type the full config hash to approve this exact dry run: ").lower() != hashes[0].lower():
        raise RuntimeError("config hash was not confirmed")
    if input("Type START to begin individual transaction confirmations: ") != "START":
        raise RuntimeError("broadcast was not approved")
    gate = ApprovalGate(env["RPC_URL"], send_url, transactions, fee_cap, coin_rows[0], owner)
    GateHandler.gate = gate
    server = ThreadingHTTPServer(("127.0.0.1", 0), GateHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        gate_url = f"http://127.0.0.1:{server.server_port}"
        live_env = dict(env, DRY_RUN="0", CONFIG_HASH=hashes[0], ETH_RPC_TIMEOUT="600", ETH_TIMEOUT="600")
        if args.local_rehearsal:
            live_env["RECORD_RPC_URL"] = env["RPC_URL"]
        live_env["RPC_URL" if args.local_rehearsal else "PRIVATE_RPC"] = gate_url
        run(["script/deploy.sh", env_name], env=live_env)
        if gate.index != len(transactions):
            raise RuntimeError(f"deploy returned after only {gate.index}/{len(transactions)} approved sends")
        last_receipt = rpc(gate.read_url, "eth_getTransactionReceipt", [gate.previous_hash])
        if not last_receipt or number(last_receipt["status"]) != 1:
            raise RuntimeError("final receipt is missing or failed")
        gate.check_previous_state(transactions[-1])
        print(f"Final receipt {gate.previous_hash}: status 1, gas used {number(last_receipt['gasUsed']):,}; expected state confirmed.")
        if args.local_rehearsal:
            print("All approved local sends, postflight and rehearsal record completed; Etherscan verification is mainnet only.")
        else:
            print("All approved sends, postflight, deployment record and Etherscan verification completed.")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError, OSError, ValueError) as error:
        print(f"mainnet-launch: stopped: {error}", file=sys.stderr)
        sys.exit(1)
