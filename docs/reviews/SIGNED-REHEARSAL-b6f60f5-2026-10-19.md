# Signed local deployment and recovery rehearsal

2026-10-19. Executable checkout `b6f60f51e9c86eef556decabeced9211b9f9f341`, with production contract bytecode unchanged from metadata candidate `9fadc14`. The frozen broad suite and deep invariants remain the `a0fa1dc` run recorded in `docs/STATUS.md`; this focused rehearsal did not repeat them.

## What ran

- Isolated Anvil at `127.0.0.1:8618`, Ethereum chain ID 1, fork block **26,208,025**, block hash `0xfee0c923e6ce4fa1c57b962cd4dbb10d85ecbd8e021867646d7e25d4f61326e6`. The Artcoin V2 factory at `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c` had code. Its current fork runtime is 16,034 bytes, code hash `0xc81a73b9453ca0e93afd762d32b98e4a9e2b157cdccd05d28fda9080f98e0c65`. Historical `eth_getCode` at the base block later failed with the public RPC's maximum proof-window error; the current factory code hash is the recorded check.
- The real factory owner `0xCB43078C32423F5348Cab5885911C3B5faE217F9` was **impersonated and pre-funded on Anvil only** to propose transferring factory ownership. The dedicated test keystore `0x59c01044b56d89110727187EFf124Bc67f11766b` accepted ownership and signed every subsequent deployment transaction. Its balance was pre-funded on Anvil. A pinned EIP-7702 delegation was injected into its local account code. None of these setup steps happened on mainnet.
- `script/config/rehearse-signer.local.json` is an ignored local copy of the launch config with only owner and creator changed to the test signer. Its signed config hash is `0x45df21262bf885b946c908d451f526de65cec56a9a1649b33ba85745d22914ea`. The selected website description and animated SVG renderer were retained.
- `script/deploy.sh rehearsal` ran the production deployment path with `DEFER_LAUNCH=1` and an approval gate. After CoreLib was sent, the original wrapper timed out at the next approval. `RESUME=state` first exposed a Forge script self-call defect. Commit `b6f60f5` replaced that self-call with the same prelaunch check in the script's own frame. `forge build` passed, independent source review agreed with the narrow fix, and a read-only `forge script script/Resume.s.sol` simulation against the partial fork passed. The signed `RESUME=state` wrapper then completed the deferred deployment and wrote `deployments/rehearsal.json`.
- `LAUNCH_ONLY=1 DRY_RUN=1 script/deploy.sh rehearsal` passed without a send. The signed launch-only wrapper then sent one individually approved factory call, ran postflight, and updated the **same** record. A separate read-only `script/Postflight.s.sol` invocation against that record passed **78/78** checks. There were no transaction failures on Anvil.

## Receipt evidence

All transactions below have receipt status `1`, value 0 ETH, and were broadcast only to local Anvil. The two factory-owner setup calls consumed 76,673 gas; the 12 production-path deployment and launch transactions consumed **21,321,799 gas**. Total including setup: **21,398,472 gas**. These are fork measurements, not a mainnet fee quote.

| Step | Block | Gas | Transaction |
|---|---:|---:|---|
| Factory transferOwnership, impersonated owner | 26208026 | 48,241 | `0x4b0dc3929fed0842481fd24c062986f0a3f220df650daeee95b7a0f790bcefc6` |
| Factory acceptOwnership, test keystore | 26208027 | 28,432 | `0xb97eb727929696e85066def37d75836507094e8b5699eac3fe6e0847746a731d` |
| CoreLib | 26208028 | 5,212,299 | `0xd5777490e62a25f20127dd2de2f1da269bd2672c4ec9d6e5de5fa5535a2fea3f` |
| CoreOpsLib | 26208029 | 968,465 | `0x62817a9eca128d2df2e4be4057dd1793aeb1eaa970eea1c3a00ef55788fd359c` |
| Core | 26208030 | 5,951,023 | `0x105feb0cc36aee55c309784060df4e66240bc3fd2c1e0180ac821398aa7bdc37` |
| ControllerV1 | 26208031 | 3,957,801 | `0x479eade49cfaa8986f95d9b1961d712b13804f44c2a65a895fab4806e15859f5` |
| Seaport adapter | 26208032 | 635,126 | `0x9332f5b9d31bd356f98cb9c6d0158a0b56bf9f7f2ef7b17b28c4f94457059879` |
| CreditStrategy adapter | 26208033 | 169,680 | `0x8b49a5e89f8c3565cea6586def7ef3ae2ce2602d9605f839146b2516e19f844e` |
| LogoCoinRenderer | 26208034 | 1,022,088 | `0x6c905505950c3b007dff25bb6a4103619864c01df74bf04e1ad8c4dfa9f1ca12` |
| Renderer setCore | 26208035 | 44,987 | `0x6c0fba4e29ebb61564730dd48ef04ee9f0da0ce6e7ca2f0ef1ad891aab8ff550` |
| Core setController | 26208036 | 63,239 | `0x3978d40a1eea082a5dc8060cefe8f7b81abdd30086f8088cf8743166f31e78a5` |
| Core allow Seaport adapter | 26208037 | 53,444 | `0x6e50d784cc17de25641798b9f8c6434ef82b7cb8b4a44a98444409284e631899` |
| Core allow CreditStrategy adapter | 26208038 | 53,444 | `0x58f3e0c752d7b336b1ffc029f36b5bb695c8cd65307df72bc9d9beb5ce4d019e` |
| Factory coin launch | 26208039 | 3,190,203 | `0xbcbfa491dda30afdbf9e733effeab53c4e1ed53cb3c044ca8b9fe2e9794dbcc5` |

## Deployed readback

`deployments/rehearsal.json` records Core deployment block 26,208,030, launch block 26,208,039, `coinLive=true`, and the config hash above. The table gives current raw `EXTCODEHASH`; the production Postflight also checked compiled runtimes with expected immutable masking.

| Contract | Address | Bytes | Raw code hash |
|---|---|---:|---|
| CoreLib | `0xd2675DF4f4ac8d599829D43b3136eAf8b0BBb653` | 23,811 | `0x36932c697fd4b07eb628b3f068921aebc7680cc653989426d59009b11f720bbf` |
| CoreOpsLib | `0x2b742485e998e392D822E355d3723cD4cc954938` | 4,226 | `0xcac4843072af32a7f5999dafb13f071a38c10a40d71352c9cb29e25e8913e023` |
| Core | `0xE8d3E2B2EECa21da0FfF1E9DEBc31aef9F5696F7` | 23,762 | `0xc937aeac3e852b567f987ae4a9dc19c8a877a5f72a0b1178917b76d0fa582f5c` |
| ControllerV1 | `0x607DA2eF7AD37E3599a51254D7E50D0564D4289f` | 17,189 | `0xbd5a81323179f22b66b7378f5a7e042760e062ee484bad66724c058459d170f9` |
| Seaport adapter | `0x32070AF32196FaE1A677E40444F860e3C96Fe8b0` | 2,536 | `0xf699c76e937852b44d9e0b5337eabb5508ee21bf779a24e4fde0171dec97f9fa` |
| CreditStrategy adapter | `0x5757788D0A6dF507dba064d66532F0b630Be1dc9` | 534 | `0xa17a41dc8c02dcbab13b02cd12d9b460efa6f8df6587144ea47d24c67da04a38` |
| LogoCoinRenderer | `0x07e24be2A69E26F74a2a7883C3d966c908099707` | 4,464 | `0xa8a40e195aa27b1cd92ffc9ac985c5afdac9a89535df57f704f70cc780edb170` |
| CC coin | `0xc56406D5bC8dF6131442690d617190dA42D6bE61` | 8,745 | `0x613c12e144c38518d7aabd2760f1147d583f80bb9d7b44f5658548411c04428f` |

## Focused same-record follow-up

Test-only commit `0ddf07e` adds an opt-in in-process fork test at the exact signed launch block. `SIGNED_RECORD_REHEARSAL=1 forge test --match-path test/SignedRecordLifecycle.t.sol -vv` exited 0 with **1 passed, 0 failed, 0 skipped**; `forge build` exited 0. With the opt-in unset, the focused file exited 0 with **0 passed, 0 failed, 1 skipped**. The test made real v4 pool-manager and hook swaps through a test router, booked **0.153633245079471893 ETH** of fee income, then bought pinned CreditStrategy listing #35,377 for **0.036 ETH** after the ETH bid rose to **0.09143598645 ETH**. Core spent **0.04045273 ETH** including royalty and caller payment; the caller received **0.00355273 ETH**. At a modeled 5-gwei base fee, this exceeded **551,839 measured test-call gas** times that base fee.

The trader was test-funded 5 ETH; Foundry impersonated callers and advanced time 31 minutes and then 24 hours. The listing was held static through that time jump, which does not prove a seller would keep it active in production. The test router used the real pool and hook, not the production Universal Router. No Anvil transaction or real keeper send occurred. This focused test covers swaps, fee booking and one acquisition on the signed record, not direct sales, pages, BALANCE, redemption, buybacks or the full end-to-end lifecycle.

## Limits and launch gate

The keeper read this same record in true `DRY_RUN=1` mode at block 26,208,039 and exited 0. It saw chain ID 1, the recorded Core and adapters, a 0 ETH pot, a 0.1 ETH reserve, zero listing candidates and an unfunded dedicated keeper wallet. All doors were enabled; its decisions sent nothing. It logged a reserve alert, but no webhook was configured or called. This proves startup and the idle decision only, not profitable execution or delivery of an alert.

The setup proves a signed, interrupted, recovered, deferred and launched **local fork path** using the production wrapper and exact local record. It does not prove control of the real factory owner on mainnet, production RPC/broadcast credentials, hosted keeper/indexer/alert operation, live website binding, production transaction fees or service behavior after launch. The prior in-process lifecycle tests are separate evidence; this signed run did not replay swaps, orders, fee booking or buybacks on its own chain state. The public RPC imposed archive proof-window limits. There is no `deployments/1.json`; the configured mainnet indexer host did not resolve during this check, and no hosted website environment was available for inspection. The launched fork record cannot pass the indexer's prelaunch-only `check-live.sh`. Production acceptance needs the final mainnet record, hosted indexer backfill and parity, public website binding, funded keeper and tested alert destination. No mainnet transaction, push or merge occurred.


## Current canonical Core Phase 1 lifecycle addendum, 2026-10-20 UTC

**Scoped Phase 1 composed E2E: pass**, combining the focused canonical-Core lifecycle below with the retained `0ddf07e` Strategy acquisition proof above. Earlier service and deployment limitations in this report describe their original observation times; current production-service evidence is in `MAINNET-SERVICES-2026-10-19.md`. This addendum does not authorize a coin launch or keeper arming.

The focused run used main `64540222a317d5ca794c5e54b46e6e3eda69956a` plus the new `test/PrecoinLifecycle.t.sol`, SHA-256 **`d67c9f53b5d99a884a680a5206e77a6a6048c4ef05dce100586795a2b79103b8`**. It forked Ethereum block **26,230,720** and read the actual `deployments/1.json` and `script/config/mainnet.json`. It bound the existing Core `0xcdb1889ae12074d750CD9B8531B692015465e0dD`, controller and both canonical adapters, required the predicted coin `0x28ef14A55DC93CDCB9001FA038A184967146C789` to have no code, and simulated only the missing factory launch through the shared `SystemDeployer._launch` helper. It did not deploy a replacement Core or call fixture setup.

The original constructor configuration and address derivation retain hash `0xe146658a6d35ea8c00acb845e9c7876850fa5682df5238f0832b0f7320820b36`, opening rate 0.0056 ETH and cap 0.0168 ETH. The fork includes the owner's actual prelaunch reset: the separate approved opening rate is **0.0097 ETH per 100 points**, cap **0.0291 ETH**, with hash `0x64804a8f4f5c68f4143537b4fd5521b1719b3583134dccc0a191500b49ededcc`. The test required that tuple through the existing signoff reader and checked every other live Core setting against the original config. It asserted the final **6,900-bps starting skim, 690-bps baseline and 4,140-second window**.

Exact focused command:

```sh
CANDIDATE_RUN=1 PRECOIN_LIFECYCLE=1 PRELAUNCH_RATE=9700000000000000 PRELAUNCH_RATE_HASH=0x64804a8f4f5c68f4143537b4fd5521b1719b3583134dccc0a191500b49ededcc MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co FORK_BLOCK=26230720 forge test --match-path test/PrecoinLifecycle.t.sol --chain-id 1 -vv
```

The command exited **0: 1 passed, 0 failed, 0 skipped**, in **32.01 seconds**. Aggregate test-call gas was **75,406,081**, covering many simulated operations, not one production transaction or a mainnet fee quote. The affected test compiled one file successfully with solc 0.8.30 in 1.80 seconds. Independent static review accepted the frozen test and the narrow fixture correction; no broad suite or signed rehearsal was repeated.

| Exercised path | Result and scope |
|---|---|
| Factory launch and swaps | Existing Core retained its recorded predicted coin; the real factory created its canonical pool in fork state. Real v4 buys and a sell delivered coin/ETH and hook income, including the initial and post-window fee stages. |
| Fee booking | Exact payee, reserve and pot shares matched actual settings; the payee latch waited until post-window income. No ETH was donated or assigned directly to Core. |
| Canonical Seaport intake | A locally signed genuine Seaport 1.6 order filled through the recorded adapter. Seller, allowed fee recipient, artist royalty, caller payment and Core cost/pot assertions passed. |
| Real-score page intake | The Seaport acquisition supplied one Credit. Another 79 real Credits were provisioned to a test seller through impersonated Strategy transfers, then sold through Core at their actual onchain-score bids. Seller payout, artist royalty, reserve headroom and pot accounting passed for each. |
| Compose and Phase 1 redemption guard | The actual credit-sale window initially held the page; after advancing time, 80 Credits composed into a real Statement held by Core. Caller accounting passed. `redeemOn` remains true, but the module is unset: `NoBalanceModule` rejected redemption without losing custody. No BALANCE/value-mode path was activated. |
| Statement sale and buyback | A test-funded buyer paid the actual controller quote. Artist/operator cuts and pot/buyback allocation matched live settings. A delayed buyback used the canonical pool, burned real coin, decreased the buyback pot and booked its hook income. |

Diagnostics reported pot **3.486968399144182900 ETH** before the synthetic page, **1.076932601403105483 ETH** before compose and **1.074490635803105483 ETH** before Statement sale. Before buyback, the pot held **8.444231958306424260 ETH** and the buyback allocation **2.456580440834439592 ETH**. Solvency assertions passed throughout.

### Preserved failure and simulation limits

The first focused run used test SHA-256 `13c65e458c7d841e27c09f05b13ca8c8aa25c8c32afbdad7675bb00299573a39` and an initial **2-ETH** synthetic trader purchase. Compilation succeeded, but execution exited **1: 0 passed, 1 failed, 0 skipped**, with `PotTooSmall()` after 37.36 seconds and 35,769,702 aggregate test-call gas. It confirmed the 0.0097 opening rate but did not complete the lifecycle. The narrow repair increased that initial purchase to **5 ETH through the real pool**, added bounded stage diagnostics and strengthened each NFT intake's reserve/funding precondition. It changed no financial assertion, production contract, setting or Core funding route. The affected rerun above passed; the first failure remains part of the evidence.

Neither checked current Strategy candidate (#22,357 or #35,377) was executable under the test's current-ask, ownership and bid-gap checks; the run logged `current pinned Strategy fill available false`. This run therefore supplies no fresh Strategy execution proof. The earlier `0ddf07e` acquisition is retained at its original block, parameters and static-listing limitation. Neither result guarantees a live listing will remain available after launch.

Factory-owner and Strategy impersonation, generated test maker/signature, test-funded traders and Statement buyer, real-Credit provisioning, test router, time/block advances and a modeled **0.2-gwei base fee** are explicit simulation boundaries. The helper's additional 1-ETH post-window purchase also used test trader funding. These artificial trades establish accounting and execution compatibility, not organic demand, expected fee volume, profitability or production keeper inclusion. No mocked score, owner economic-setting change, Core donation, deployment-record write, signed mainnet transaction, Anvil broadcast, production wallet funding, mainnet coin/pool launch or keeper arming occurred. Actual postlaunch service behavior and venue availability remain future observations; phase-two activation is outside this proof.
