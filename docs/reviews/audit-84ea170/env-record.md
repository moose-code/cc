# Environment record (audit of ripe0x/cc)

- repository: ripe0x/cc, fresh clone, `origin/main` = `84ea170ab3330a4163ef8ac00cb5fa2cd067fe09` (2026-10-18 19:36:49 -0400,
  "Merge pull request #110 from ripe0x/codex/indexer-smoke-diagnostics"). Audit branch `claude/hopeful-hamilton-nt5h8x` at the same commit.
- toolchain: forge 1.8.1 (982849d3, 2026-08-28), anvil 1.8.1, solc 0.8.30 (svm), node v22.22.0, npm 10.9.4, python 3.13.16.
  foundry installed from the v1.8.1 release tarball (foundryup's attestation download is refused by the session proxy).
- compiler settings (foundry.toml): default profile solc 0.8.30, cancun, optimizer 200, bytecode_hash none; production
  contracts (src/[A-Z]*.sol, CoreLib, CoreOpsLib, CreditDrawing, adapters) forced onto the `viair` profile: via_ir, optimizer 200.
  isolate on in tests (per STATUS), dynamic_test_linking true, fuzz runs 256, invariant runs 32 depth 64.
- submodules: forge-std f3dae6e (v1.17.0), solady d07f92e (v0.1.25), v4-periphery ad04c9f (df47aa9), v4-core 59d3ecf (v4.0.0-12),
  permit2 cc56ad0. `forge build` rewrites foundry.lock (restored with git checkout after every run).
- clean build: 7m00s wall. Runtime sizes (bytes): Core 23,674 (margin 902), CoreLib 23,635 (margin 941), ControllerV1 17,189,
  CoinRenderer 8,241, LogoCoinRenderer 4,464, CreditStrategyAdapter 534, SeaportBasicAdapter (see sizes table in log).
- deployment config: script/config/mainnet.json (owner, creator, payee 0xCB43078C32423F5348Cab5885911C3B5faE217F9; artist
  0xc8f8e2f59dd95ff67c3d39109eca2e2a017d4c8a; rateStart 4.9e15, rateCap 1.47e16; skim 690 bps, bounty 9,000, sniper 9,000 over 1,800 s;
  supply 1e27; salt 0x56d9...8a9c). anvil.json and rehearsal.json differ only in image and description.
- live stack (script/config/v2-mainnet.json): factory 0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c (deployed block 26202473),
  hook 0x866F31562dDe70D7B989C2529a9deFFFFd3bE8CC, locker 0xbD049E96..., escrow 0xB65816a3..., mev 0x32Ab8Ec0..., tokenDeployer 0x99EB38d6...,
  burnRouter 0x183751c6..., feeController 0xbD5A853f..., launcher commit 6d099486.
- fork for tests: anvil fork of https://eth.drpc.org at block 26222700 (chain id 31337 node, tests run with `--chain-id 1`),
  MAINNET_RPC_URL=http://127.0.0.1:8545, FORK_BLOCK=26222700. The factory has 16,034 bytes of code at that block and none at
  the `.env.example` pin 26158000 (verified with eth_getCode on two public archive RPCs).
- Jack's balance token: jckbtchr-vv/credits at 9318c713974ee18658ac5aeddab45f0e1e45b585 built with script/tools/upstream-balance.sh
  (an `xxd -r -p` shim was needed; the container has no xxd). Creation sha256 and the three runtime hashes matched the script's pins;
  out/upstream-balance.json written (ConversionLineageWithdrawals, runtime 0x29b369bc...c3bd).
- mainnet head at the time of the audit: 26222950.
