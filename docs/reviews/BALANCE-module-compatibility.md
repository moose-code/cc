# Compatibility of StatementBalanceModule with Jack's redemption contract

Scope: engine main `a6441ea7eb2c05d3558b16f84bccf047965757d4`, token replacement PR 32 and the module in PR 33 (decisions 142 and 144).

Upstream: `jckbtchr-vv/credits` at `38cdb26cc80431d103221f729cdcf63c0b93b060`, `contracts/src/experimental/AuctionLineageWithdrawals.sol` and its base `LineageWithdrawals.sol`. Compiler solc 0.8.28 via IR, optimizer 200. Creation bytecode SHA-256 `980130b1bedb50d2f226fce4509ed80011780ff04d0641eafbdae4e6aeb89a08`. `script/prepare-upstream-balance.py` and `test/UpstreamBalance.t.sol` both enforce the revision and the hash. The private source and bytecode are not vendored.

## Module rules

- `unitPerPoint` is `1e14`. A four-decimal raw score becomes an 18-decimal BALANCE amount.
- `redeem(sid)` is callable by the Core. It reads `creditScoreOf(sid)`, quotes, approves that statement, withdraws, and reverts `RedeemedBelowRating` when the module's balance rose by less than `creditScoreOf * unitPerPoint`. The upstream contract holds the surrendered Statement. Receipts and artwork history belong to the module.
- `available()` returns 0 until `totalRetired == launchRetirement` and `block.number >= transfersOpenBlock`, then the module's token balance. Upstream sets `totalRetired` once, in `retireLaunchSupply`, behind a `totalRetired != 0` revert, so it is 0 or `launchRetirement`.
- `pay(to, amount)` is callable by the Core and reverts above `available()`.
- `migrateReserve()` is callable by anyone after Core retirement. It sends the module's whole balance to the successor's current module when that module is a distinct contract bound to the successor and to the same token. Repeat calls move later proceeds.
- Binding getters do not authenticate code. The owner selects the successor and its module, as with Core migration.

## Tests

`test/StatementBalanceModule.t.sol` uses public doubles of Statements and the token. It covers the constructor checks, Core-only calls, redemption at and below the rating, both launch gates (retired total below, equal and above `launchRetirement`), payment limits, and migration cases: retired and live Core, invalid and hostile successors, a module bound to another token, and a token callback that re-enters `migrateReserve` and `pay`.

`test/UpstreamBalance.t.sol` runs the real upstream bytecode on a fork: missing renderer registration rolls back custody, opening does not bypass creator retirement, redemption before opening fills the module while `available()` is 0, spendable balance at opening, an affordable page of real Credits purchased, recomposed and redeemed again, duplicate redemption fails, and Core retirement migrates the reserve to the real successor Core's bound module including later proceeds. One Statement funds a page of 80 Credits only when the page's ratings fit the pot, so the test selects an affordable page from the strategy's current holdings. The test skips when `out/upstream-balance.json` is absent and fails instead when `REQUIRE_UPSTREAM_BALANCE=true`.

## Reproduce

```
python3 script/prepare-upstream-balance.py /path/to/credits
forge build src/adapters/StatementBalanceModule.sol
STACK=live FORK_BLOCK=26205390 PORT=<free port> FORK_URL=<archive rpc> script/dev/anvil.sh
forge test --match-path test/StatementBalanceModule.t.sol -vv
STACK=live MAINNET_RPC_URL=http://127.0.0.1:<port> FORK_BLOCK=0 REQUIRE_UPSTREAM_BALANCE=true forge test --chain-id 1 --match-path test/UpstreamBalance.t.sol -vv
```

Fork block 26205390, factory `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`. Upstream renderer registration and funder retirement use test impersonation. No transaction is sent to Ethereum.

## Results at c37caf0

45 focused tests passed with no skips: 28 replacement, owner and build-identity tests on the live-stack fork, 12 module tests and 5 upstream tests. `script/tools/gen-interfaces.sh --check` passed. Core, CoreLib and Controller build identities were unchanged. Module runtime is 2,402 bytes. Independent source review of c37caf0 found no remaining actionable findings.

## Limits

This is implementation compatibility evidence. It does not cover Jack's auction lifecycle, the real auction pool, market throughput or production gas. Before activation, authenticate the live contract, constructor parameters, renderer registration, creator retirement, opening block and canonical pool (docs/RUNBOOK.md, wiring the production balance module).
