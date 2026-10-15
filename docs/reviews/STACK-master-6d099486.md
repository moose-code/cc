# the master stack candidate exercise (6d099486)

the engine retargeted to the artcoins v2 stack at launcher commit `6d099486` (`script/config/v2-master.json`).
every run is against the master stack fork fixture: `STACK=master`, an anvil loaded from
`script/dev/.cache/stack-master-26158000.hex` on chain id 31337, the forge scripts and the suite re-entering chain id
1 with `--chain-id 1`, `FORK_BLOCK` unset. the fixture owner is the dev wallet
`0xCB43078C32423F5348Cab5885911C3B5faE217F9`, so one key owns the factory and the engine.

toolchain: foundry 1.8.1, engine solc 0.8.30 via_ir, artcoins ci profile.

## whole suite plus the seven deep invariant suites (one invocation)

`CANDIDATE_RUN=1 INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 STACK=master
MAINNET_RPC_URL=http://127.0.0.1:8602 forge test -j 8 --chain-id 1`

- 88 test suites, 534 tests: 530 passed, 2 failed, 2 skipped. 1224 s wall (8032 s cpu).
- the deep invariant env runs every invariant suite (the regular Phase1/Phase1Window/Phase2/Hostile/SalePhase1/SalePhase2
  set and their seven `*Deep` mirrors) at 64 runs x 200 depth; all pass except the one below.
- the 2 skips are `test/Rehearsal.t.sol` (runs under `REHEARSAL=1`, below) and
  `ConfigTest.test_preflightPinsTheOwnerDelegation` (the mainnet owner's 7702 pins do not apply to the fork owner).

### the 2 failures are pre-existing engine edges, not the port

the port changes only `src/interfaces/ArtCoinsV2.sol` and `src/lib/CoreLib.sol` (the buyback `hookData`); `src/Core.sol`,
`src/ControllerV1.sol`, the pause clock and the balance bid are byte for byte unchanged (`git diff fa060ae HEAD -- src/`).
both failures are in that unchanged engine code, surfaced by this run's fuzz and invariant seeds; the earlier whole suite
runs on other seeds passed them. they are for the engine team to triage, not the artcoins retarget.

1. `PauseClockTest.testFuzz_ageIsWallTimeMinusPausedTime(uint256)` fuzz counterexample at `args=[17050]`: the paused age
   price is `100812511668089968` against the curve's `93862916563755907` (a ~7.4% gap at that age). deterministic for that
   input; foundry had not generated age 17050 on the earlier seeds. controller pause-clock price, untouched by the port.
2. `InvariantsSalePhase2Deep.invariant_11_noUnexpectedReverts`: `sellForBalance` reverted `PotTooSmall()` (0x086aef59) in
   a shrunk sequence that set a setting to 8_000_001 and then sold for balance with extreme inputs. the balance bid's pot
   solvency guard; the handler does not allow-list `PotTooSmall`. balance-bid math (decisions 117, 122), untouched by the
   port.

## rehearsal

`REHEARSAL=1 STACK=master MAINNET_RPC_URL=http://127.0.0.1:8602 forge test --chain-id 1 --match-path test/Rehearsal.t.sol`

- 1 passed, 0 failed. 6 s.
- preflight (metadata-only expected row), the real deploy path as the factory owner, postflight (all rows pass, the coin
  unlocked), and the smoke (buy, sell, book with the payee share, a credit sold into the bid) through the master factory.
  launch gas 3,183,178; `factory: deployToken accepts the config (simulated)` passes.

## local end to end (PHASE=post)

`NO_ANVIL=1 E2E_RPC_URL=http://127.0.0.1:8604 PHASE=post STACK=master script/dev/e2e.sh` on a second anvil from the dump.

- `LOCAL END TO END PASSED (PHASE=post)`. 415 s.
- the deploy (`script/deploy.sh local`, chain id 31337 node, `--chain-id 1` scripts, dev wallet the factory and Core
  owner) wrote `deployments/31337.json`; the seed deployed the balance token and module; every scenario stage ran and the
  credit price fell over its window and a statement reached its floor.
- gas per stage: a 1,426,509; adopt 544,920; balance-bid 974,547; buyback 211,450; claims 387,658; compose-a 8,831,927;
  compose-b 8,604,633; compose-d 8,514,742; d-buy 801,537; d-open 1,122,012; dev-wallet 190,077; fill-a 15,962,291;
  fill-b 15,751,696; fill-d 15,752,273; format 51,689; fresh-compose 9,316,561; fresh-fill 15,068,797; pause 60,587;
  redeem 247,560; settings 340,793.

## the port's own paths

the retarget's launch, fee, lock and refund paths all pass against the master stack (in the whole suite above):
`V2StackTest`, `V2PortFeeTest` (the partial fill refund to the `hookData` address, the escrow credit booked to the pot),
`V2PortSkimTest` (`lowerBaselineSkim` lowers the engine fee per swap, `lock()` freezes it, the protocol leg lands at the
fee controller at 1,000 bps of the baseline), `V2PortMigrationTest`, `V2PortRestrictionTest`, `ConfigTest`, `LockTest`,
`BuildIdentityTest` (the build pins and sizes), `FeesTest`, `ReviewMatrix*` and `ReviewDeploy*`.

## the second candidate run at eab58c7 (every gate green)

the two failures above are fixed at the root (not papered over) and the whole suite reruns green on the master stack
fixture. the fix of the pause-clock fuzz counterexample is a wrong expectation in the test: the price check compared the
controller quote against the statement cost, but `priceOf` prices on the reference `max(valueOf(rating), cost)`, which
the bid floor rate lifts above cost at low total elapsed time; the age clock itself was correct. the balance-sale
`PotTooSmall` is the invariant handler's model, not the Core: `_pickBalanceIds` now mirrors the `CoreLib._fillBalance`
floor rule (review ac8da10 M1), offering no batch whose available-clamped rate would fall below the floor. the engine
`src/` is byte for byte unchanged from the first run; only `test/Pause.t.sol`, `test/invariant/HandlerBase.sol` and
`test/BalanceFloor.t.sol` changed, each with a hand-derived unit test for the exact state (`test_ageAtSeed17050`,
`test_sellForBalanceRefusesWithTinyAvailable`).

`CANDIDATE_RUN=1 INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 STACK=master
MAINNET_RPC_URL=http://127.0.0.1:8602 forge test -j 8 --chain-id 1`

- 88 test suites, 536 tests: 534 passed, 0 failed, 2 skipped. 886 s wall (5892 s cpu).
- the deep invariant env ran every invariant suite and its `*Deep` mirror at 64 runs x 200 depth; all pass, including
  `InvariantsSalePhase2Deep::invariant_11_noUnexpectedReverts`.
- the 2 skips are `test/Rehearsal.t.sol` (runs under `REHEARSAL=1`, below) and
  `ConfigTest.test_preflightPinsTheOwnerDelegation` (the mainnet owner's 7702 pins do not apply to the fork owner).
- the test count is 536 (was 534): the two root-cause unit tests are the two new tests.

rehearsal: `REHEARSAL=1 STACK=master MAINNET_RPC_URL=http://127.0.0.1:8602 forge test --chain-id 1 --match-path
test/Rehearsal.t.sol` — 1 passed, 0 failed. 3 s. preflight, the owner deploy path, postflight and the trading smoke
through the master factory.

simulator parity: `node sim/engine.test.mjs` — 1,804 checks passed (the port follows decisions 116 to 126 and reads the
launch config from `script/config/mainnet.json`), at or above the 1,765 of the prior freeze.
