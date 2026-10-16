#!/usr/bin/env python3
"""Copy a compiled private-source candidate into ignored out/ for integration tests."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

REVISION = "38cdb26cc80431d103221f729cdcf63c0b93b060"
root = Path(sys.argv[1]).resolve()
if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() != REVISION:
    raise SystemExit("Upstream checkout must be at the reviewed commit")
subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", "contracts/src", "contracts/foundry.toml"], cwd=root, check=True)
subprocess.run(
    ["forge", "build", "src/experimental/AuctionLineageWithdrawals.sol", "--skip", "test", "--skip", "script"],
    cwd=root / "contracts", check=True,
)
artifact = json.loads((root / "contracts/out/AuctionLineageWithdrawals.sol/AuctionLineageWithdrawals.json").read_text())
creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
if hashlib.sha256(creation).hexdigest() != "980130b1bedb50d2f226fce4509ed80011780ff04d0641eafbdae4e6aeb89a08":
    raise SystemExit("Creation bytecode differs from the reviewed upstream build")
artifact["upstreamCommit"] = REVISION
destination = Path(__file__).resolve().parent.parent / "out/upstream-balance.json"
destination.parent.mkdir(exist_ok=True)
destination.write_text(json.dumps(artifact))
print(f"Prepared {destination} from {REVISION}")
