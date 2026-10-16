# Current-main compatibility with Jack's redemption contract

Scope: engine current main `a6441ea7eb2c05d3558b16f84bccf047965757d4`, plus token replacement PR #32 and this production module. Main advanced from `496f2f9` during implementation; the newly merged change configures the deployed Artcoins stack rather than changing Core's runtime sources. The earlier legacy-engine review is not current-main evidence.

Upstream snapshot: `jckbtchr-vv/credits` main `38cdb26cc80431d103221f729cdcf63c0b93b060`, `contracts/src/experimental/AuctionLineageWithdrawals.sol` and its base `LineageWithdrawals.sol`. Contract sources are unchanged from the earlier `c3bdcba` snapshot, but the integration assertions are rewritten for current main's module custody. Compiled using upstream solc 0.8.28, via IR, optimizer 200; creation bytecode SHA-256 `980130b1bedb50d2f226fce4509ed80011780ff04d0641eafbdae4e6aeb89a08`. The helper and test both enforce this hash and the source revision. Private source and compiled bytecode are not vendored.

The adapter implements the current `IBalanceModule`: `balanceToken`, live-readable `unitPerPoint`, `redeem`, `available`, `pay`. Four-decimal raw scores multiply by `1e14` to become 18-decimal BALANCE; a whole point therefore becomes one BALANCE. Core measures the actual increase in the module's holdings, and payments leave that module directly for the seller. The source NFT stays permanently in Jack's contract. Receipt and artwork history accrue to the module, and token ink/history accounting preserves transferred quantities.

Acceptance cases: missing renderer registration rolls back NFT custody and receipts; opening does not bypass creator retirement; after retirement, redemption before opening succeeds into module custody while available is zero and selling Credits fails without moving them; at opening the balance becomes spendable; a funded affordable page of real Credits is purchased, recomposed and redeemed again; duplicate redemption fails; Core retirement permits same-token reserve transfer to the real successor Core's bound module, including later Statement proceeds.

Budget caveat: one Statement does not fund every arbitrary group of 80 Credits, because ratings differ. An initial test incorrectly assumed equal-count pages cost the same; it hit the existing `PotTooSmall` protection. The integration uses an affordable page selected from real strategy-held Credits, filtering current ownership because the dated fixture includes subsequent sales, and bounds paid units between the configured 90 percent floor and 100 percent cap. This is interface/custody verification, not a market-throughput or self-funding guarantee. The general Fixture bypasses the ETH purchase cap while assembling its initial page; this test does not verify launch purchase-budget economics.

Reproduce with a clean authorized upstream checkout at the pinned revision and its pinned dependencies:

```
python3 script/prepare-upstream-balance.py /path/to/credits
forge build src/adapters/StatementBalanceModule.sol
# Start in a separate terminal, using an archive-capable Ethereum RPC:
STACK=live FORK_BLOCK=26205390 PORT=8613 FORK_URL=<rpc-url> script/dev/anvil.sh
forge test --match-path test/StatementBalanceModule.t.sol -vv
STACK=live MAINNET_RPC_URL=http://127.0.0.1:8613 FORK_BLOCK=0 REQUIRE_UPSTREAM_BALANCE=true forge test --chain-id 1 --match-path test/UpstreamBalance.t.sol -vv
```

The test skips only when the optional private-source artifact is absent and `REQUIRE_UPSTREAM_BALANCE` is unset; required verification sets it true so missing preparation fails. Fork upstream: Ethereum block `26205390`, with the deployed factory `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`, served by this task's isolated Anvil on port 8613. Upstream renderer registration and funder retirement use local test impersonation. No transaction is sent to Ethereum.

Verification results: 45 unique focused Forge tests passed, zero final skips: 28 affected replacement/owner/build-identity tests on the recent live-stack fork, 12 adapter unit tests, and five real-upstream tests. The live-stack combined run passed 31/33; only the two cycle tests reran after repairing the dated test fixture's ownership filtering, and both passed. Initial tests also exposed and corrected the equal-count affordability assumption; no production runtime repair was needed. Exact final commands:

```
STACK=live MAINNET_RPC_URL=http://127.0.0.1:8613 FORK_BLOCK=0 REQUIRE_UPSTREAM_BALANCE=true forge test --chain-id 1 --match-path 'test/{BalanceTokenReplacement,OwnerPowers,BuildIdentity,UpstreamBalance}.t.sol' -vv
STACK=live MAINNET_RPC_URL=http://127.0.0.1:8613 FORK_BLOCK=0 REQUIRE_UPSTREAM_BALANCE=true forge test --chain-id 1 --match-path test/UpstreamBalance.t.sol --match-test 'test_(exactOpeningRedeemsAndRecyclesIntoCredits|retirementMigratesReserveAndLaterRedemption)' -vv
```

The module unit file ran separately with `--chain-id 1 --match-path 'test/{StatementBalanceModule,UpstreamBalance}.t.sol'`; its 12 tests passed. At that first run the optional integration artifact path was incorrect and skipped; the required runs above use the corrected path and forbid a missing artifact. Zero-skips verification of all five actual cases is established by the three unchanged passing cases plus the final two passing cycles, not by the earlier skip.

Targeted production build passed; `script/tools/gen-interfaces.sh --check` passed. Existing Core/CoreLib/Controller build identities passed unchanged after the main-stack merge. New module runtime is 2,402 bytes; creation-artifact SHA-256 is `a9511c9063c506338b1810df6d59954169b603ae228a59bb5f29d2a2c479d218`. Independent source reviewer `/root/review_current_main` found no contract blocker at isolated snapshot `1ed6d81`. Review requested clarification that successor/module getter checks do not authenticate code; documentation now explicitly retains the existing owner trust. Final independent source review of immutable commit `c37caf0` by `/root/review_current_main` covered ancestry, upstream source, final ownership-aware helper, generated interface and documentation. No remaining actionable findings. The reviewer did not rerun the reported tests. Source and evidence are consistent for the requested implementation scope; release prerequisites remain open. No release or deployment acceptance. Final live BALANCE identity, constructor parameters, renderer registration, supply retirement, opening block and canonical pool remain activation prerequisites. Tests do not run Jack's complete auction lifecycle or initialize its real auction pool; they make no claim about final auction pricing/liquidity or production gas costs.

Task cleanup: the isolated task-owned Anvil instances on 8612 (old fixture) and 8613 (live stack) were stopped after verification. No owner node was changed.
