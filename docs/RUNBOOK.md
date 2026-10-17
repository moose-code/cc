# runbook

the launch, the owner commands after it, and what to do when something stops half way. the rules are docs/SPEC.md. every number here comes from the code, the config or the latest rehearsal record (docs/reviews/REHEARSAL-<candidate>.md, named by the freeze table in docs/STATUS.md). the owner sends every mainnet transaction; the owner address is an EIP 7702 delegated account, so every multi transaction broadcast uses `--slow`.

## 0. what you need

| item | note |
|---|---|
| the live v2 stack | the five stack addresses are in the tracked script/config/mainnet.json (factory 0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c, the deployed ArtcoinsFactoryV2); the recorded stack with its code hashes is script/config/v2-mainnet.json, pinned by preflight |
| the signer | one key does every transaction: the v2 factory owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9, also the config `owner` and `creator`, the Core owner and the payee. `deployToken` is owner only on the deprecated factory. the wrapper signs with a foundry keystore (`KEYSTORE_ACCOUNT`, a name under ~/.foundry/keystores) and a password file outside the repository (`PASSWORD_FILE`); both come from the shell or from script/env/mainnet.env, and the wrapper refuses while either is empty |
| eth | the deploy fee (0 at the pin, read live, the factory's `deployFee()`) plus gas for eleven transactions, 19,069,638 gas measured on the master stack fixture: 0.019 eth at 1 gwei, 0.095 at 5 gwei, 0.381 at 20 gwei. fund about 20 percent over the figure for the expected base fee |
| read rpc | an archive capable mainnet rpc in `MAINNET_RPC_URL`, for every command that does not send |
| private rpc | `PRIVATE_RPC`, a relay that does not publish to the public mempool and serves `eth_getCode`, `eth_getStorageAt` and `eth_call` (https://rpc.mevblocker.io did when tested) |
| etherscan key | `ETHERSCAN_API_KEY` for verification |
| the toolchain | foundry 1.8.1, solc 0.8.30. `forge build` rewrites foundry.lock and lib/solady: `git checkout foundry.lock; git submodule update -- lib/solady` before any commit or gate |

## 1. the launch, commands in order

| step | action | command or note |
|---|---|---|
| 1 | local config | `cp script/config/mainnet.json script/config/local.json` (gitignored). `image` (at most 2048 bytes, with a scheme) and `description` (at most 4096 bytes) may stay empty: the coin renderer draws the image and reads the description from the coin, so `description` is the coin's description text. a renderer is bound to one Core: after a launch attempt that created the renderer, a config change that moves the Core address needs a new `salt`, and preflight fails `predicted renderer is empty` until then. set `rateStart` to the market price on launch day of 100 points in wei and `rateCap` to 3 times that refreshed deploy-morning rateStart (preflight checks the ratio against the rateStart it is deployed with). set `artist` to the artist's address (the tracked file holds the decided launch address). review every value against docs/SPEC.md section 3 |
| 2 | rehearse | `REHEARSAL=1 LAUNCH_CONFIG=script/config/local.json forge test --match-path test/Rehearsal.t.sol -vv`: a fork of the latest block, the owner command, the whole deploy, postflight and a trading smoke. it prints the gas of each transaction and the eth the owner needs at 1, 5 and 20 gwei. the addresses it prints are the CREATE2 addresses the launch will use |
| 3 | owner command on the factory | the factory's minimum protocol skim share is 1,000 and the launch needs at most 1000: `cast send $FACTORY "setMinProtocolSkimShareBps(uint16)" 1000 --rpc-url $MAINNET_RPC_URL --ledger`, confirm with `cast call $FACTORY "minProtocolSkimShareBps()(uint16)"`. after step 6, set it back to 1,000 in its own transaction |
| 4 | preflight and sign off | `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL \| grep -E '^ +(WARN\|FAIL\|[0-9]+ of\|CONFIG_HASH\|signoff)'`. 118 rows, every one ok (WARN rows never fail). `script/config/v2-mainnet.json` carries the current treasury of the protocol fee controller, which the artcoins owner can change at any time, and preflight refuses on drift. read the `signoff:` rows. `export CONFIG_HASH=0x...` from the printed value |
| 5 | dry run | `DRY_RUN=1 script/deploy.sh mainnet` (with `CONFIG_HASH` exported). evaluates every guard of step 6, runs preflight and simulates every transaction of `Deploy`; nothing is signed or sent and no wallet is read. a failed git guard (tree, branch, freeze table) prints a warning; every other failed guard is listed at the end and the exit status is 1. the empty `KEYSTORE_ACCOUNT` and `PASSWORD_FILE` values fail it until set. the balance row of the dry run reads high; the funding check is step 4's row and a direct `cast balance $DEPLOYER` |
| 6 | broadcast | `CONFIG_HASH=$CONFIG_HASH PRIVATE_RPC=... ETHERSCAN_API_KEY=... KEYSTORE_ACCOUNT=<name> PASSWORD_FILE=<path outside the repo> script/deploy.sh mainnet`. in order: the guards (the keystore address is `DEPLOYER`, the config `owner` and the factory owner; `CONFIG_HASH` is the hash preflight prints for the launch config; the git tree is clean on main after `git checkout foundry.lock; git submodule update -- lib/solady`; `script/tools/check-freeze.sh` exits 0, every row of the freeze table ok; no `deployments/1.json` yet), the build, preflight, `Deploy` through `PRIVATE_RPC` with `--slow`, a wait for the Core and the coin on the read rpc, `Postflight` (73 rows, every one ok), the record, then verification (section 3). it prints `start block <n>` before the first transaction. the set back of step 3 follows |
| 7 | the record | the wrapper writes `deployments/1.json` from the `record:` line of `Postflight` (addresses read back from the chain) and the block of the Core creation: a temporary file in `deployments/`, checked for the shape web, keeper and indexer read (every address, `deployBlock`, `poolFee`, `tickSpacing`), then moved into place. the file is gitignored and carries `rpcUrl: null`. keeper: the file in `deployments/` of the keeper checkout (`RECORD=<path>` reads another). indexer: `indexer/deploy.sh mainnet` reads it. web: `jq -r '"NEXT_PUBLIC_CORE=\(.core)","NEXT_PUBLIC_DEPLOY_BLOCK=\(.deployBlock)","NEXT_PUBLIC_STRATEGY_ADAPTER=\(.strategyAdapter)","NEXT_PUBLIC_SEAPORT_ADAPTER=\(.seaportAdapter)"' deployments/1.json` prints the four values for the web host environment (web/.env.example) |
| 8 | postflight | the wrapper ran it before writing the record. rerun at any time: `CORE=$CORE DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. 73 rows, every one ok; the locked recipients row is a WARN until `lockRecipients`. record the start tick it prints and the date as the launch price |
| 9 | the window's end | the keeper (section 8) sends `book()` at the first block past the factory launch time plus live `settings.sniperSeconds` (1,800 seconds at launch) with income pending. by hand if the keeper is down: `cast send $CORE "book()" --rpc-url $PRIVATE_RPC` from any account but the owner key (the `/keeper` web page has the button). the first book with income latches the payee share and shares none of that income; later books apply `payeePpm` |
| 10 | later owner decisions | `lockRecipients` (with `lockSuccessor`), `lockAllowlist`, the balance side, the credit sale, chosen composition: section 4 |

the eleven transactions of step 6, in order: the library `CoreLib`, the Core, the controller, the Seaport adapter, the CreditStrategy adapter, the coin renderer `CoinRenderer` (constructed with the config owner), `setCore` on the renderer (binds the Core, once), `setController`, `addAdapter` twice, `deployToken` with the fee, which names the renderer in the token config. the creations go through the deterministic deployer (CREATE2) at addresses that depend on the config and the salts; a contract with code at its address is skipped and a call whose effect is on chain is skipped, so a stopped run continues from the chain (section 6).

what the scripts refuse: `Deploy` and `Resume` refuse an unset placeholder, a value out of bounds, a `CONFIG_HASH` that is not the hash of the loaded config, a signer that is not the factory owner, and the flags `SETTINGS_CHANGED` or `COIN_CHANGED` in the environment (each turns failed postflight rows into warnings after an owner change; only `Postflight` honors them). `script/deploy.sh` adds the guards of step 6 and refuses a private key on its command line or in the environment of the keystore env.

## 2. the sign off table

preflight prints a `signoff:` row for each block below; the owner confirms each against docs/SPEC.md section 3 before step 6.

| block | rows |
|---|---|
| the bid | `rateStart` (market price on launch day of 100 points, wei), `rateCap` (3 times it), `pointsPerPage` 35,200 (80 credits times the census 440), `climbMultiplierCapBps` 40,000, `spendCapBps` 10,000 (off), `bucketSeconds` 60, `idleStepSeconds` 600 and the other bid settings |
| the sale | `saleFloorBps` 10,000, `saleToBuybackBps` 2,500, the `Sale` struct (markup 15,000, cap 100,000, decay hours 4, anchor half life 604,800, anchor min cost 0.1 eth, `anchorMoveBps` 0) |
| the credit side | `creditCostToPotBps` 8,000, `chosenComposeOn` false, `minCcToChoose` 1e18, `saleOn` true, `window` 14,400, `spreadBps` 1,000 (the floor is 11,000 of the reference at the cap of 10,000, today's 1.1x; decision 155 keeps 1,000 at launch, 200 at the value switch of decision 153), `startBps` 15,000 (`pointsPerPage` is a bid setting above) |
| the credit swap | `swapFeeCc` 10,000e18 (ten thousand coins burned per `swapCredit`) |
| the balance side | `redeemOn` true, `balanceBidOn` false, `redeemSlippageBps` 200, `balanceBidMarginBps` 1,000, `balanceBidCapBps` 10,000, `redeemBurnBps` 2,000, `feeToRedeemBurnBps` 1,000 |
| the keepers | `buybackSlice` 0.5 eth, `buybackDelay` 25, `keeperFee` 0.0003 eth, `keeperMaxBaseFee` 5 gwei, `callerFee` 0.0003 eth, `callerMaxBaseFee` 3 gwei (decision 138) |
| the payee and the artist | `payee` the owner, `payeePpm` 0 at launch (the owner raises it later), `settings.sniperSeconds` 1,800; `artist` the launch artist address; the nft sale cuts `saleToArtistBps` 250, `saleToOperatorBps` 50 |
| the adapters | the Seaport recipient allowlist (the OpenSea fee collector 0x0000a26b00c1F0DF003000390027140000fAa719) |
| the coin | name CC, symbol CC, supply 1e27, start tick -175000, position -175000 to 887200, skim 1,000 bps, bounty 9,000, lp fee 0, sniper 9,000 bps over 1,800 s, protocol 2,000 bps, restricted, allowlist empty, image, description |
| the build | the masked runtime code hashes of the five contracts and the library creation hash |

## 3. verify on etherscan

after step 6, for each of the Core, the controller, the two adapters, the coin renderer and the library: `forge verify-contract <address> <path>:<name> --chain 1 --etherscan-api-key $ETHERSCAN_API_KEY --constructor-args <args> --libraries src/lib/CoreLib.sol:CoreLib:$LIB` where postflight prints the constructor args of the Core and the controller, the renderer's constructor arg is the config owner, and `LIB` is the library address from `broadcast/Deploy.s.sol/1/run-latest.json`. the compiler settings are foundry.toml's (solc 0.8.30, via_ir, optimizer 200).

## 4. after the launch

### owner commands

all by the owner, effective at once. the settings scripts dry run unless `SEND=1` and `--broadcast`.

| what | how |
|---|---|
| a Core setting | `script/SetSettings.s.sol`: `SET_<field>=<value>` for each changed field, `SET_RATE=<wei>` for `setRate`; with `CONTROLLER=$CONTROLLER` it drives `setSale` and `setCredit`. the script preserves unnamed live fields; `SETTINGS_PATCH` accepts an inline JSON object or file of Core settings, then `SET_<field>` overrides it |
| lowering the spend cap in an incident | `CORE=$CORE SET_spendCapBps=50 SEND=1 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --slow --account <keystore>`. a lower cap applies to the live bucket immediately, and a higher cap does too: the budget is recomputed from the bucket's snapshot and the spent amount is kept |
| pause and resume | `cast send $CORE "setPaused(bool)" true` and `false` |
| the payee | `cast send $CORE "setPayee(address)" <to>`; the payee fee share and the operator cut are pushed by the book and the sales, not claimed |
| the artist | `cast send $CORE "setArtist(address)" <to>`; the artist cut of nft sales is pushed to it (the zero address is refused while `saleToArtistBps` is nonzero) |
| the adapters | `addAdapter(address)`, `removeAdapter(address)`, `lockAdapters()`; on the Seaport adapter `setAllowedRecipient(address,bool)`. in the first days watch `buyListing` reverts for `RecipientNotAllowed` and add the recipient that Credits listings carry |
| the credit sale window | on at launch; `setCredit` with `saleOn` false closes it and true reopens it; read `creditPrice(id)` back |
| chosen composition | `setChosenComposeOn(bool)`, `setMinCcToChoose(uint96)` (also the gate of `setHeldFormat`) |
| the balance side | once the balance module is written and verified: `setBalanceModule(address)` (replaceable until `lockBalanceModule()`), then `setSettings` with `balanceBidOn` (`redeemOn` is true at launch), then on the controller `setBalancePoolKey((address,address,uint24,int24,address))` with native eth as currency0 and the balance token as currency1 once its pool is live. when the balance token's auction is announced: `setPaused(true)`, reprice with the live settings, `setPaused(false)` |
| the reserve | `releaseRedeemBurn(uint256)` moves reserve eth into the buyback pot |
| composing | `compose()`, `compose(uint8)` or `composeChosen` when nobody else does; switch the payment on with `callerFee` and `callerMaxBaseFee` if pages sit |
| the coin | `coin.lockRecipients()` (script/Lock.s.sol: postflight, then the lock) seals the bounty recipient and ends fee stream migration; take it together with `lockSuccessor`. `lockAllowlist()`, `unrestrict()`, `renounceAdmin()`, `setMetadataRenderer`, `updateImage`, `updateDescription` are the coin admin's |
| the coin's metadata renderer | named in the token config by the launch (`CoinRenderer`, transactions 6 and 7 create and bind it). to replace it: deploy the new renderer, then `cast send $COIN "setMetadataRenderer(address)" $RENDERER --rpc-url $MAINNET_RPC_URL --ledger` (the coin refuses an address without code); `setMetadataRenderer(address(0))` returns to the built in json; `renounceAdmin()` freezes the choice. read back `cast call $COIN "metadataRenderer()(address)"` and `cast call $COIN "tokenURI()(string)" \| head -c 200`; `CORE=$CORE COIN=$COIN script/tools/coin-metadata.sh` decodes the live metadata into files and a viewer. after a replacement run postflight with `COIN_CHANGED=1` |

### editing economic settings

`Settings` has 37 fields in five storage slots. the original 29 include `climbMultiplierCapBps`; then `spendCapBps` (uint16), `bucketSeconds`, `balanceBidCapBps`, `idleStepSeconds` and `sniperSeconds` (uint32 each), `reserveWei` (uint64), `returnLockSeconds` (uint32) and `valueModeOn` (bool). the controller's six-field `Sale` appends `anchorMoveBps` (uint16). update integrations to these tuples before using the new contracts; INTEGRATION section 13 gives the ABI order.

preview a patch without sending:

```sh
CORE=$CORE CONTROLLER=$CONTROLLER SET_spendCapBps=100 SET_bucketSeconds=60 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL
```

`SetSettings` prepares the complete batch from live structs before executing any setter, and validates the exact setter order as the owner inside a temporary EVM snapshot, then restores every simulated write. it prints the Core before/after table and calldata, plus controller calldata when changed. with `CONTROLLER` set, sale fields use `SET_markupBps`, `SET_startCapBps`, `SET_decayHours`, `SET_anchorHalfLife`, `SET_anchorMinCost`, `SET_anchorMoveBps`; credit fields use `SET_saleOn=0|1`, `SET_window`, `SET_spreadBps`, `SET_startBps`. the JSON patch applies to Core fields only. unspecified fields keep their live values, single-field environment values override JSON, unknown fields and values wider than their ABI types are refused.

the setter order is `setSale` first when its new markup satisfies the old Core floor, then changed `setSettings`, optional nonzero `SET_RATE`, a deferred `setSale` when lowering markup requires the new Core floor first, then changed `setCredit`. the final Core floor must fit the final markup. raising the Core floor and markup together therefore raises markup first; lowering both past the old floor lowers the Core floor first. `SET_RATE=0` skips the rate setter. a rate cap below the live bid or price state prints a warning because the bid falls when applied.

after reviewing the preview, the owner can send the same inputs with `SEND=1`, `--broadcast`, `--slow` and the chosen signer. these are separate transactions, so an interruption may leave earlier setters applied; read the live structs and rerun the preview before continuing. preview restores simulated writes and does not grant permission to broadcast.

the ETH purchase cap applies to direct seller payouts and adapter listing price plus actual keeper payment. the cap is off at launch (`spendCapBps` 10,000); lower it during an incident. `SET_spendCapBps=10000` bypasses enforcement and still records outflow; switching it back on retains that spending. a changed cap reprices the original active snapshot, and a changed bucket duration carries active spent, snapshot and both bids' active drop floors forward. changing settings never resets active spent to zero. if spent already exceeds a lowered budget, new purchases wait for the next bucket or a higher budget. ETH bid views omit budget headroom, so simulate the purchase and handle `SpendCapReached(spent,cost,budget)` even with a nonzero bid and a funded pot. the first purchase of a bucket always passes, so a pot whose budget is under one credit still buys one credit per bucket. balance purchases have no ETH cap.

`settings.sniperSeconds` controls only the one-way payee latch relative to the factory's launch timestamp. changing it cannot undo `payeeOn`, and `setSettings` books income under the old settings before applying the new ones. it does not change `launch.sniperSeconds`, the external pool's launch skim schedule. the two launch defaults are both 1,800 seconds; read the live Core setting for later book timing.

### the value switch (decision 148)

value mode prices the eth bid off the shared balance instance times the controller's protected value of the balance token, and prices the engine's sales off the same value with the cost term dropped (SPEC section 4). it is off at launch and needs the balance side live. in order:

1. the balance module is set and verified, the controller's `setSale` and `setCredit` are at the packet values (`spreadBps` 200), and the controller holds the balance pool key (`setBalancePoolKey`), which starts the reference at the pool spot.
2. the owner chooses the reference price inputs left at 0 in the config (`referenceRateBpsPerHour`, `referenceStepBps`, `referenceMaxStale`, `minLiquidity`; `tolBps` is 500 and `referenceMinSeconds` 600) and sends them on the controller: `cast send $CONTROLLER "setQuote((uint32,uint16,uint16,uint32,uint32,uint128))" "(<rate>,<step>,500,<maxStale>,600,<minLiquidity>)"`. the intended pool-time values are `referenceRateBpsPerHour` 1,200, `referenceStepBps` 200 and `referenceMinSeconds` 600, so the cadence is `referenceStepBps / referenceRateBpsPerHour` and one refresh per cadence moves one full step. preflight warns while the inputs are pending.
3. call `refreshReference()` on the controller (anyone may) until `valuePerPoint(false)` answers `ok` true and `referencePrice()` sits within `tolBps` of `spotPrice()`; the reference moves at most the rate times the elapsed time per call and runs at most once per `referenceMinSeconds`, so a reference far from the spot takes hours.
4. one `setSettings` with `valueModeOn` true, `balanceBidOn` true, `balanceBidCapBps` 11,000, `balanceBidMarginBps` 1,000, `climbPerMinBps` and `recoveryClimbPerMinBps` 100 and `saleFloorBps` 5,000: `CORE=$CORE SET_valueModeOn=1 SET_balanceBidOn=1 SET_balanceBidCapBps=11000 SET_balanceBidMarginBps=1000 SET_climbPerMinBps=100 SET_recoveryClimbPerMinBps=100 SET_saleFloorBps=5000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL` (switches take 1 or 0), then the same with `SEND=1 --broadcast`. turning `valueModeOn` on resets the shared instance to the floor, so the eth bid opens at 90 percent of value.
5. read back `ethRate()`, `balanceRate()` (9,000), `floorMultBps()` (11,220) and `creditPrice` of a pile credit; the keeper's `refreshReference` door keeps the reference tracking from here (section 8), and the `quote` alert fires if it goes stale.

while the quote is unusable `sellForEth`, `buyListing`, `ethRate` and the controller's sale doors revert `NoQuote`; `sellForBalance`, compose, redemption, the buyback and `book` keep running. to leave value mode send `setSettings` with `valueModeOn` false; the eth instance resumes from its stored state.

### bounds and coupled checks

bounds use the declared unsigned integer width where no narrower limit follows. uint16 max is 65,535, uint32 max is 4,294,967,295. the defaults stay the launch values; wider bounds make owner choices possible and do not promise sensible economics for every combination.

- `dropPer100PointsBps` is 1 to 9,999; `dropFloorBps`, `saleToBuybackBps`, `recoveryGapBps`, `redeemSlippageBps`, `balanceBidMarginBps`, `redeemBurnBps`, `feeToRedeemBurnBps` and `creditCostToPotBps` are 0 to 10,000. artist plus operator sale cuts must total strictly less than 10,000; an artist cut also requires a nonzero artist. `payeePpm` is 0 to 1,000,000.
- `climbPerMinBps` and `idleLoosenBps` are 1 to uint16 max; `recoveryClimbPerMinBps` is at least `climbPerMinBps` and at most uint16 max. `ceilBps` and `climbMultiplierCapBps` are 10,000 to uint16 max. `saleFloorBps` is 0 to uint16 max and no higher than controller markup. `buybackDelay` is 1 to uint16 max blocks. `peakHalfLife`, `pointsPerPage`, `bucketSeconds` and `idleStepSeconds` are 1 to uint32 max; `sniperSeconds` is 0 to uint32 max. `balanceBidCapBps` is 10,000 to uint32 max; raising it leaves the floor at `10,000 - balanceBidMarginBps`. `spendCapBps` is 1 to 10,000, with 10,000 the bypass value.
- `rateStart`, `rateCap` and `setRate` accept 1 to uint64 max wei; `setRate` must also fit live `rateCap`. `buybackSlice` is 1 to uint128 max wei and at least `2 * (600,000 * keeperMaxBaseFee + keeperFee)`. `keeperFee` and `callerFee` are 0 to uint64 max, their base-fee ceilings 0 to uint48 max, and `swapFeeCc` is 0 to uint96 max base units. caller payments remain capped at the pot; listing keeper payment remains capped at the bid gap and pot left.
- sale markup is 10,000 to uint16 max, at least the Core floor and at most `startCapBps`; `startCapBps` is markup to uint32 max; `decayHours` is 1 to uint16 max; `anchorHalfLife` is 1 to uint32 max seconds; `anchorMinCost` is 0 to uint128 max; `anchorMoveBps` is 0 to 10,000 (launch 0). zero anchor movement leaves the sale anchor clock unchanged. credit window is 1 to uint32 max seconds, credit floor is 10,000 to uint16 max, and credit start is 10,000 to uint32 max.

### the lock table

| lock | closes | take it when |
|---|---|---|
| `lockController()` | `setController` | the pricing policy is final |
| `lockBalanceModule()` | `setBalanceModule` (needs a module set) | the redeem rate is known to be fixed |
| `lockAdapters()` | `addAdapter` and the Seaport allowlist additions | the venues are final |
| `lockSuccessor()` | `setSuccessor` (with the successor zero it disables `migrate`) | the next engine is chosen or no migration is wanted |
| `coin.lockRecipients()` | the bounty recipient of the pool | with `lockSuccessor` |

### moving to a successor engine

1. deploy and verify the successor (a Core built with the live coin address, which takes `fund()`), set its controller and adapters.
2. as coin admin, point the pool's bounty recipient at the successor (`setBountyRecipient` on the hook), so fees flow there from the next swap.
3. `setSuccessor(successor)` on the old Core, then dry run `migrate` on a fork (`cast call $CORE "migrate(uint256)" 150 --from $OWNER`), then `migrate(150)` repeatedly until `ethPot` and the pile are 0 (about 44,800 gas per credit; 370 is the largest batch under the cap). the balance token is held by the module, not the Core, so migrate has no balance leg. the first call retires the old engine.
4. on the successor: `adopt` the credits it received, and set its balance module (which holds the token; there is no `bookBalance`). the old engine keeps selling and redeeming its statements and burning its buyback pot.

### keeper duties

| duty | call | paid |
|---|---|---|
| sweep a listing below the bid | `buyListing(adapter, id, params)`, simulate for available bucket budget first | gas at the base fee up to 5 gwei plus 0.0003 eth, at most the gap and pot left; gas accounting adds 350,000 overhead and caps counted gas at 1,500,000 |
| burn | `buyback()` every 25 blocks while the buyback pot holds at least twice the largest payment | gas plus the scaled fee |
| compose | `compose()` when `nextPage()` is ready | gas at the base fee up to 3 gwei plus 0.0003 eth (decision 138) |
| redeem | `redeemStatement(sid)` when `atFloor(sid)` and `redeemOn` | like compose; reverts `NoBalanceModule` until the module is set |
| book | `book()` at the window's end, `collectEscrow()` if the escrow holds a credit for the Core | nothing |

the owner keeper (`keeper/`, section 8) runs every duty from launch (decision 136); the table is also the manual fallback on the `/keeper` web page.

### a dump that walks the bid down, and statements above the floor

at launch settings the bid climbs 2 percent a minute below and above the recovery level (`recoveryClimbPerMinBps` and `climbPerMinBps` are both 200, decisions 151 and 155). the ETH purchase budget also limits how much a dump can sell per bucket; time until fills resume depends on that budget and the fixed bucket boundary. `setRate` restates the bid and the peak at once if the owner wants it faster. statements bought above market sit at their reference until the market reaches it or the balance side opens; lower `saleFloorBps` to sell them below cost, which reaches every held statement at once.

### watching the buyback after a price fall

the 0.5 eth slice is unprofitable to sandwich down to about a quarter of the launch pool depth (about 94 percent below the launch price). read the pool tick weekly against the launch record; past a 90 percent fall set `buybackSlice` to 0.2 eth, past 98 percent to 0.1 eth.

## 5. what cannot change after the launch

the skim (10 points), the bounty split (9,000 of 10,000), the protocol recipient, the ticks and the supply are fixed in the pool and the coin. the Core's stack, coin and `RATE_START` are immutables; a new stack or a new coin is a new Core. everything in docs/SPEC.md section 3 is adjustable.

## 6. when a transaction fails half way

every state between the eleven transactions is safe: the library is stateless, the controller and the adapters are inert until the Core points at them, and a Core without a controller holds nothing and refuses its controller doors. nobody else can launch the predicted coin, because `deployToken` is owner only on the deprecated factory.

```sh
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12     # 0x... means the Core exists
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12     # 0x means the launch is not sent
```

| state | recovery |
|---|---|
| nothing or only the library sent | rerun `script/deploy.sh mainnet`; what has code is skipped |
| the Core sent, the launch not | `RESUME=state CORE=$CORE FROM_BLOCK=<start block of the first run> script/deploy.sh mainnet`: runs `Resume`, which creates what has no code, sends the renderer, `setCore`, the owner calls and the launch that are missing, then postflight, the record and verification. it refuses a `CORE` that is not this config's address (`CoreMismatch`), no Core (`NotStarted`), a launched coin (`AlreadyLaunched`) |
| the forge run stopped with transactions left in its saved file | the delegated owner account allows one transaction in flight and rejects nonce gaps (`gapped-nonce tx from delegated accounts`, `in-flight transaction limit reached`), so a run can land the first transaction and fail the rest. read `cast nonce $DEPLOYER` and the nonces in `broadcast/Deploy.s.sol/1/run-latest.json`. while the nonce lies from the first saved nonce to the first plus the number of saved transactions: `RESUME=replay CORE=$CORE FROM_BLOCK=<start block of the first run> script/deploy.sh mainnet` runs `forge script --resume --slow`, which sends only the transactions without a receipt, then postflight, the record and verification. outside that range the wrapper refuses and the row above applies |
| launched | `RESUME=record CORE=$CORE FROM_BLOCK=<start block of the first run> script/deploy.sh mainnet` sends nothing and runs postflight, the record and verification; then step 9 |

## 7. local end to end

an anvil fork of block 26158000 (chain id 31337) with the system deployed by the launch scripts, a seed and a scenario that fires every user and keeper door. the web app reads the record `deployments/31337.json` (gitignored).

| item | how |
|---|---|
| start the chain | `script/dev/local.sh` leaves anvil running on port 8545 (`PORT=` changes it). the first run builds the state with `script/dev/e2e.sh` (about 5 minutes, most of it the seed's credit transfers) and saves it under `script/dev/.cache/`; a later run with unchanged src, script, test/standins and test/utils loads the saved state in seconds. `FRESH=1` rebuilds, `script/dev/local.sh stop` stops anvil |
| the run itself | `script/dev/e2e.sh` starts its own anvil, runs everything and stops it. `KEEP=1` leaves anvil running, `STOP_AFTER=<stage>` stops after a stage, `NO_ANVIL=1` and `E2E_RPC_URL` reuse a node. `FORK_URL` is the archive rpc, the Tenderly public gateway by default |
| deploy | `script/deploy.sh local` funds the factory owner, lowers `minProtocolSkimShareBps` to 1000 and restores it, then runs Preflight, Deploy (`--unlocked --broadcast --slow`) and Postflight. the scripts require chain id 1, so forge runs with `--chain-id 1` |
| phase `pre` | the credits move to three accounts (`script/dev/Seed.s.sol`); the balance bid and chosen composition start off; the credit sale and `redeemOn` follow the config |
| phase `post` (default) | the seed also deploys `MockBalanceToken` and `MockBalanceModule` (which mints `rating * unit` on redeem), mints the token to the Core, creates an eth / balance pool at the config's `dev.balancePoolSqrtPriceX96` with full range liquidity from the trader, then as owner sets the module, books the balance, switches `redeemOn`, `balanceBidOn`, the credit sale and chosen composition on, and sets the controller's pool key |
| stages | `script/dev/Scenario.s.sol`, one `STAGE` per forge run: `a` (coin trades, `book`, payee latch), `dev-wallet` (the dev wallet buys coin), `fill-a` (`sellForEth` both forms), `adopt`, `compose-a` (`compose()`, `buy` at `priceOf`), `claims` (raises `payeePpm`, then a booked buy pushes the payee share, the `FeesAdded` amount; the sale cuts are the pushed amounts of `StatementSoldTo` and `CreditSold`), `d-open`, `d-buy` (`buyCredit`, `buyCredits`), `fill-b`, `compose-b` (`composeChosen`), `format` (`setHeldFormat`), `settings` (`setSale`, `setCredit`, `setRate`, `setSettings`, `fund`), `pause`, `buyback`; in `post` also `fill-d`, `compose-d` (`compose(uint8)`), `redeem` (`redeemStatement`, `releaseRedeemBurn`), `balance-bid` (`sellForBalance` both forms); then `fresh-fill`, `fresh-compose`, `report`. node time warps run between the stages |
| the record | `chainId`, `rpcUrl`, `deployBlock`, the five contracts and the library, the live Credits, Statements, pool manager and hook, `poolFee`, `tickSpacing`, `owner`, `accounts` (a1, a2, a3, keeper, trader), `phase`, and in `post` `balanceToken`, `balanceModule` and `balancePool` (`null` in `pre`) |

The dev wallet `dev.wallet` of `script/config/anvil.json` (the owner's browser wallet, recorded as `accounts.owner`) is funded by the seed with `dev.walletEth` eth, `dev.walletCredits` credits, coin bought with `dev.walletCoinEth` eth (stage `dev-wallet`, the coin is restricted to pool trades) and, in `post`, `dev.walletBalance` of the balance token; change the address there and rerun `script/dev/local.sh` (the web app lists the injected wallet next to the mock accounts and signs `owner` with it).

`buyListing` is outside the scenario: the CreditStrategy lists at about four times the rate cap and the Seaport adapter prices an order that needs an external signature.

### the master stack fork fixture (STACK=master)

`script/config/v2-master.json` records an artcoins v2 stack at launcher commit `6d099486` deployed onto a mainnet fork at block 26158000. The fork is built on chain id 1 (the launcher's `DeployV2Stack` requires it), then the state loads onto the chain id 31337 local node, so the owner's wallet and the web local mode keep their 31337 network entry. The owner is the dev wallet `0xCB43078C32423F5348Cab5885911C3B5faE217F9`, so one key owns the factory and the engine as on mainnet. It is a fork deployment, not a mainnet stack. `STACK=master` points the fixture, the scripts and the local end to end at this record and loads the deployed state from `script/config/stack-master-26158000.hex` (tracked). The default stays the live stack of `script/config/v2-mainnet.json`.

The dump is tracked so CI can load it (`.github/workflows/ci.yml` and `candidate.yml` start an anvil from it). Rebuild it:

1. Fork mainnet at the pin block on a free port, chain id 1:
   `anvil --fork-url <archive rpc> --fork-block-number 26158000 --chain-id 1 --port 8601 --auto-impersonate --retries 10 --timeout 60000`
2. Clear the dev wallet's 7702 delegation on the fork (it carries a mainnet delegation at this block):
   `cast rpc anvil_setCode 0xCB43078C32423F5348Cab5885911C3B5faE217F9 0x --rpc-url http://127.0.0.1:8601`
3. From a worktree of the launcher at `6d099486` with `OWNER` and `TREASURY` set to the dev wallet in `script/v2/env/local.env`, deploy the stack onto the fork:
   `RPC_URL=http://127.0.0.1:8601 DRY_RUN=0 script/v2/deploy.sh local`
   (`script/v2/env/local.env` sets chain id 1, profile ci, treasury bps 8000, deploy fee 0. The verify step's chain check reports one wiring drift because master lists the hook and the fee controller as escrow depositors, not the locker; the deploy and the readback pass.)
4. Dump the fork state:
   `cast rpc anvil_dumpState --rpc-url http://127.0.0.1:8601 | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin))' > script/config/stack-master-26158000.hex`

The dump is anvil_dumpState gzip hex, loadable through the `anvil_loadState` rpc, not `anvil --load-state`. `STACK=master script/dev/anvil.sh` forks at chain id 31337 and loads the state after startup; the engine's forge scripts re-enter chain id 1 with `--chain-id 1` and the test suite runs with `--chain-id 1`. After `anvil_loadState` the loader pins the dev wallet's nonce to the upstream value at `FORK_BLOCK` (`anvil_setNonce`): the dump carries the nonce from its build block (26158000), so rebuilding the owner's chain on a fork at a later block would otherwise have a seed `CREATE` (the mock balance token) land on the address a contract the mainnet wallet has since made already occupies, and the seed reverts. At the default 26158000 fork this is a no-op.

### activity speed run against the running local chain

`script/dev/activity.sh` acts on the deployment in `deployments/31337.json` (its `rpcUrl` is the node) in rounds. It reads the record and sends transactions; it deploys, seeds and resets nothing, and exits on a node that is not chain id 31337.

```
script/dev/activity.sh eth [rounds]       default 5 rounds
script/dev/activity.sh balance [rounds]   eth rounds plus the balance side (needs the post phase module)
script/dev/activity.sh both [rounds]      eth rounds, then balance rounds
SEED=<n>  PAUSE=1  QUIET=1  PEOPLE=<holders>  PEOPLE_CREDITS=<credits per holder>  BOT_MARGIN=<wei>  WARP_MIN/WARP_MAX=<seconds>
```

Each round warps the node 2 to 4 hours, then runs one `forge script` (`script/dev/Activity.s.sol`, `round(bool)`) that sends every action as an impersonated account through the real doors and quotes (`bidOf`, `priceOf`, `creditPrice`, `balanceBidOf`), after a dry run of each call in the simulation. A round prints its actions, then the pot, the bid, the pile, the held statements, the statements sold, the CC burned, the action counts of the run and the last transaction of each kind as an `evm.now` link. During the run the node produces one second per block (`anvil_setBlockTimestampInterval`) so the quotes read by the simulation stay current; the script restores the interval on exit.

| step | what it does |
|---|---|
| trading | 6 to 12 universal router swaps from 20 derived addresses: buys of 0.05 to 2 eth, sells of 10 to 60 percent of the CC an address holds; `book` after |
| bots | `buyListing` through the CreditStrategy adapter for every watched listing priced under `bidOf(id)` minus `BOT_MARGIN`, best gap first, until none qualifies. The watched listings are the first 200 ids of `test/utils/CreditIds.sol` that break even at a rate under 1.5 times the rate cap (the strategy has no enumeration, only `nftForSale(id)`); prices are read live. Seaport listings are swept the same way from the signed listings file |
| people | 2 to 5 real Credits holders at the fork block (EOAs found by sampling ids with `ownerOf`) sell 1 to 3 credits through `sellForEth` at the quote; two more name an ask above the bid and print `held out` |
| compose | `compose(format)` with a random format from a derived address when `nextPage()` is ready (80 credits past their window) |
| buyers | 1 to 3 statement purchases at `priceOf`, 1 to 4 credit purchases at `creditPrice`, from derived addresses that can pay; `buyback` from the bot when eligible |
| balance (balance rounds) | the node warps until a held statement `atFloor`, then 1 to 2 `redeemStatement`, 1 to 3 real holders `sellForBalance` at `balanceBidOf`, 1 to 2 holders `sellForEth` for contrast; the summary shows the balance rate in percent of par and the module's `available()` |

Real on the fork: the CreditStrategy listings and prices, the Credits holders and their credits and scores, the Uniswap v4 pool, the OpenSea listings. Simulated: the 20 trader, bot and composer addresses (funded with `anvil_setBalance`), the sizes and timing of their actions, the mock balance token and its module. `activity.sh balance` and `both` leave 2 held statements to the buyers (`HOLD_BACK`) so the redemptions have input. Pile growth is slow at the default of 3 credits per holder (compose needs 80); `PEOPLE_CREDITS=30` reaches it in a few rounds.

Caches under `script/dev/.cache/` (gitignored): `activity-<core>.json` (watched strategy listings and sampled holders, built on the first run), `opensea-<core>-<catchup>.json` (the OpenSea fetch, reused for an hour, `REFRESH=1` refetches). A second invocation on the same chain starts at the round.

Seaport listings: `OPENSEA_API_KEY` in the shell environment (never written to a file) makes `script/dev/opensea-listings.mjs` fetch the best listing of each Credits token (`listings/collection/credits/best`), keep the ones a basic order can fill (one Credits offer, native consideration, open order type, recipients the offerer or allowlisted, held by the offerer at the fork block, started within the run's warps), rank them by price over score and fetch the signature of the 40 cheapest from `listings/fulfillment_data`. The round dry-runs each fill on the fork (`fulfillable on the fork now`) and sweeps those under the bid. Seaport derives its EIP-712 domain separator from `block.chainid` and the OpenSea signatures cover chain id 1, so on a chain id 31337 node every fill reverts `InvalidSigner()`. The OpenSea sweep runs on a chain id 1 fork of a block near the head (the listings have started and their offerers still hold the credits):

```
N=$(cast block-number --rpc-url https://gateway.tenderly.co/public/mainnet)
CHAIN_ID=1 FORK_BLOCK=$((N-100)) STACK=master PORT=8609 script/dev/anvil.sh        # loads the master stack dump
CHAIN=1 NO_ANVIL=1 E2E_RPC_URL=http://127.0.0.1:8609 PHASE=post STACK=master script/dev/e2e.sh   # deploys, seeds, writes deployments/1.json
OPENSEA_API_KEY=... REFRESH=1 RECORD=deployments/1.json script/dev/activity.sh eth 5
```

The record carries chain id 1, so the evm.now links of this node point at chain id 1 and resolve only on the local node. The sweep needs the bid above a listing's price plus `BOT_MARGIN`; the bid climbs 2 percent a minute toward the rate cap, so the first sweeps come in the second or third round. On the pinned 26158000 fork the orders are newer than the fork, and `SEAPORT_CATCHUP=1` warps the node past their start once at the start of the run (the fills still need chain id 1). `SEAPORT_ORDERS=<file>` replaces the fetch with a file of the format `{"count": N, "orders": [{"id": "<credit id>", "price": "<wei>", "params": <BasicOrderParameters, decimal strings, additionalRecipients as {amount, recipient}>}]}`, which `script/dev/opensea-listings.mjs` also writes.

## 8. the keeper

`keeper/` is the owner keeper of decisions 136 to 139: one node process that calls every keeper door from its own hot wallet, never the owner key (decision 57). it reads the state once per block (the shared `readSnapshot` of `packages/engine` plus the keeper's reads, pinned to one block), decides with pure functions (`keeper/src/decide.ts`), simulates each call with `eth_estimateGas` from the keeper, rechecks the profit rule at the measured gas, and sends one transaction at a time through the private relays, waiting for its receipt before the next. a paid door goes only when the Core pays at least its own gas at the worst base fee plus its tip plus `MARGIN_ETH`; every skip is logged with its reason.

| priority | door | when |
|---|---|---|
| 1 | `buyListing(adapter, id, params)` | a CreditStrategy or Seaport listing has sat under `bidOf(id)` and under the pot, net of the keeper's cost, for `LISTING_DELAY_SEC` (2 minutes, decision 137), the order is open and its offerer still holds the credit; best gap first. while `spendCapBps` is under 10,000 the keeper reads `spendState()` and skips a listing whose price plus keeper payment the bucket budget cannot take (the first purchase of a bucket always passes) until the next bucket; a `SpendCapReached` simulation is a wait |
| 2 | `buyback()` | `ethToBuyback` above 0, `lastBuybackBlock + buybackDelay` reached, the slice at least `2 * maxPay` and the scaled fee covering the tip |
| 3 | `compose()` | `nextPage()` ready; paid 3 gwei plus 0.0003 eth (decision 138), so it waits above about 3 gwei |
| 4 | `collectEscrow()` | the fee escrow holds more for the Core than the gas of the claim |
| 5 | `book()` | `launchedAt + settings.sniperSeconds` passed, `payeeOn` false, income pending: the book that latches the payee share |
| 6 | `redeemStatement(sid)` | `atFloor(sid)`; logged only while no balance module is set (it reverts `NoBalanceModule`) |
| 7 | `refreshReference()` on the controller | the pool key is set, `referenceMaxStale` is nonzero and `referenceMinSeconds` has passed since the last sample (`referenceTime`); unpaid, about 60,000 gas. the pool-time cadence is `referenceStepBps / referenceRateBpsPerHour` (200 / 1,200 = 600 s), so one refresh per cadence moves one full step and keeps the reference both tracking and fresh. in value mode with the reference unusable every listing is skipped with `NoQuote` |

### environment

every value is an environment variable; nothing secret is written to a file by the keeper or this repo. the OpenSea key and the webhook come from the shell or the host's secret store.

| variable | default | meaning |
|---|---|---|
| `RECORD` | `deployments/<CHAIN_ID>.json` | the deployment record (section 7 shape): `core`, `controller`, `seaportAdapter`, `strategyAdapter`, `chainId` |
| `RPC_URLS` | | read rpcs, comma separated, first preferred. on mainnet the keeper appends the public fallbacks (Tenderly gateway, drpc, publicnode) and logs `rpc fallback answered` when one is used |
| `RELAY_URLS` | MEV Blocker, then Flashbots Protect (decision 139) | private relays for `eth_sendRawTransaction`, tried in order. a live chain refuses to start without one |
| `KEYSTORE`, `KEYSTORE_PASSWORD_FILE` | | the keeper's v3 keystore (`cast wallet new <dir>`) and a file holding its password, both mounted secrets. decrypted in memory |
| `DRY_RUN=1` with `KEEPER_ADDRESS` | | simulate and log `dry run: would send` for each call, send nothing; no key needed |
| `MAX_BASEFEE_GWEI_<DOOR>`, `MAX_PRIORITY_GWEI_<DOOR>` | 5 for `BUY_LISTING` and `BUYBACK`, 3 for the rest; tip 0.05, 0.02 for `COMPOSE` | per door ceiling and tip (`MAX_BASEFEE_GWEI` and `MAX_PRIORITY_GWEI` set all). a transaction's `maxFeePerGas` is the ceiling plus the tip, so it never lands above the ceiling |
| `MARGIN_ETH` | 0.00005 | what a paid door must clear above its own cost |
| `DAILY_BUDGET_ETH` | 0.2 | the net eth (gas spent minus Core payments) the wallet may lose per UTC day; a send whose gross cost does not fit waits |
| `LISTING_DELAY_SEC` | 120 | decision 137 |
| `BOOK_MIN_ETH` | 0.01 | once the payee share is latched, the keeper books when the pending income (Core balance above the booked pots) exceeds this |
| `BOOK_MIN_SEC` | 600 | the keeper's last book must be older than this for the latched book above, so booked state follows income at a bounded gas cost |
| `STRATEGY_IDS` | `Credits.tokensOf(strategy)` | the CreditStrategy ids to watch, or `off`; refreshed every `STRATEGY_REFRESH_SEC` (600). The default set is kept by delta from the Credits Transfer logs of the strategy (state file `STATE_DIR/strategy-inventory.json`), with a rolling re-read of 300 prices per refresh and a full read once a day |
| `STRATEGY_FULL_READ` | | `1` reads the whole strategy inventory on every refresh (first start, or a node without log queries) |
| `INDEXER_URL` | | indexer origin (https or local); seeds the strategy inventory on the first start from `strategy_listing` instead of `tokensOf` |
| `OPENSEA_API_KEY` | | enables the Seaport source (`packages/engine/src/opensea.mjs`), refreshed every `OPENSEA_REFRESH_SEC` (300); `SEAPORT_ORDERS=<file>` reads the same shape from a file instead |
| `ALERT_WEBHOOK_URL` | | JSON POST `{source, key, text, ...}` for alerts (decision 139) |
| `LOW_BALANCE_ETH` | 0.05 | alert under this wallet balance |
| `BREAKER_THRESHOLD`, `BREAKER_PAUSE_SEC` | 3, 3600 | consecutive failures of a door (an on chain revert, a send no relay took, a receipt that never came) that pause it, and for how long |
| `DOORS` | all | a comma list to run only some doors |
| `STATE_DIR` | `keeper/.state` | the daily ledger files (amounts and hashes only) |
| `RPC_TIMEOUT_MS` | 20000 | per request read timeout; a local fork with a cold upstream needs 120000 |

### start

```sh
npm ci                                  # repo root: installs web/, keeper/ and packages/engine
cast wallet new ~/keeper-keystore       # once: the keeper's own key, never the owner's
RPC_URLS=$MAINNET_RPC_URL KEYSTORE=... KEYSTORE_PASSWORD_FILE=... ALERT_WEBHOOK_URL=... \
  OPENSEA_API_KEY=... npm start --workspace keeper
```

at start the keeper refuses the owner address 0xCB43078C32423F5348Cab5885911C3B5faE217F9 and the Core's `owner()`, refuses an rpc whose chain is not the record's, warns when the keeper address carries EIP 7702 delegation code (`0xef0100`), and logs its whole configuration with secrets reduced to whether they are set. on Fly.io or Railway (decision 139) the service runs `npm start --workspace keeper` from the repo root with node 22.18 or later; the keystore and the password file are mounted secrets and `STATE_DIR` a volume.

### dry run

```sh
DRY_RUN=1 KEEPER_ADDRESS=<keeper> RPC_URLS=$MAINNET_RPC_URL npm run tick --workspace keeper   # one tick, then exit
```

each line is one JSON object. `skip` names a door and why it waits; `dry run: would send` carries the call, the simulated gas, the Core payment and the keeper's cost; `intended (logged only)` is a redemption while no module is set. run it before the first live start and after any settings change.

### funding and top up

the keeper spends gas and is repaid by the Core on the paid doors; `book`, `collectEscrow` and `observe` are unpaid. hold about 0.1 eth (a compose needs about 9 million gas of headroom, 0.045 eth at 5 gwei, repaid in the same transaction). the `balance` alert fires under `LOW_BALANCE_ETH`; top up with a plain send from any account. the ledger (`STATE_DIR/ledger-<day>.json`) shows the day's spend, receipts and count.

### alerts

| key | meaning | action |
|---|---|---|
| `breaker:<door>` | the door failed `BREAKER_THRESHOLD` times in a row and is paused | read the `reverted on chain` or `send failed` lines; a revert after a passing simulation is a lost race or a relay problem |
| `budget` | the day's net loss reached `DAILY_BUDGET_ETH` | read the ledger; raise the budget or wait for the UTC day |
| `balance` | the wallet is under `LOW_BALANCE_ETH` | top up |
| `tick` | five ticks in a row failed to read the chain | check the rpcs |
| `quote` | value mode is on and the controller's reference price is unusable (the reference older than `referenceMaxStale`, the pool under `minLiquidity`, or no spot or unit read), so `ethRate` reverts `NoQuote` and the eth routes wait | check the `refreshReference` door and the pool; call `refreshReference()` by hand, or lower `minLiquidity` or raise `referenceMaxStale` with `setQuote` |
| `reserve` | the pot (with the pending fee share) is at or under `reserve()`, so the eth bids read zero and the keeper skips every listing (`ReserveHeld`); compose, redeem and buyback still pay from the whole pot | wait for fee income, or lower `reserveWei` with `setSettings` if the floor is too high for the pot |

### manual override

the `/keeper` web page has `book`, `buyback` and the pots for any wallet; `compose()` is on `/compose`. stop the keeper (or set `DOORS` without the door) before acting by hand on the same door, so two senders do not race. pausing the engine (`setPaused`) does not stop the keeper's buybacks or sweeps.

### tests

| what | how |
|---|---|
| unit, every gate at its boundary | `npm test --workspace keeper` |
| one tick per door against the local stack | `STACK=master script/dev/local.sh`, then `npm run e2e --workspace keeper` |
| the Seaport sweep on a chain id 1 fork | `CHAIN_ID=1 STACK=master PORT=8609 script/dev/anvil.sh`, `CHAIN_ID=1 STACK=master RPC_URL=http://127.0.0.1:8609 script/deploy.sh local`, then `npm run e2e:seaport --workspace keeper`. it signs its own order with a key made in memory; with `OPENSEA_API_KEY` in the shell it also checks the live fetch against the adapter |

### Replacing the balance token

For a replacement that keeps the current redemption value floor, pause sales and set balanceBidOn off during setup. Verify the replacement module and token and the current upstream launch gates, then call setBalanceModule and read back balanceModule, balanceToken and the module's unit and available(). Each module keeps its own token reserve, so a replaced module's holdings stay in that module; re-select it to spend them.

Call setBalanceModule first and setBalancePoolKey second: the setter requires currency1 to equal balanceToken(), so the key follows the token. Set the replacement's complete pool key before resuming sales that rely on its value floor. Simulate a redemption and a token-pinned sell, then restore the owner-selected switches and sales.

Before lockBalanceModule, read the old module's available(), run the old module's owner migrate or confirm its reserve is spent, then lock. lockBalanceModule freezes the module and the token. This preparation authorizes a mainnet action only on the owner's explicit instruction.

### Wiring the production balance module (decision 144)

No deployment or activation is authorized by the implementation PR. Before activation: authenticate Jack's live contract against the reviewed source, and confirm its Statements address, score unit, registered renderer, exact creator retirement and opening block. `ready()` reports renderer registration only. Confirm the canonical ETH/BALANCE pool, fee, tick spacing and hook; a failed auction may leave no pool. The constructor validates interface metadata, not code identity.

The owner deploys `StatementBalanceModule(core, balanceToken)` and wires it in this order, one transaction each:

1. `setBalanceModule(module)` on the Core. Read back `balanceModule`, `balanceToken` and `unitPerPoint`.
2. `setBalancePoolKey((address,address,uint24,int24,address))` on the controller, with native eth as currency0, the balance token as currency1 and the confirmed pool parameters. Read back the key.
3. `setSettings` with `balanceBidOn` once `available()` reads the module's token balance.

`script/deploy.sh` (PR 35) ends at the postflight and the record, whose `balanceModule` and `balancePool` fields are null. Its post-launch step for this module is a wrapper change in a separate PR; until it lands the three calls above are the wiring.

For successor migration, deploy a module bound to the successor Core and the same token and set it on the successor before retiring the old Core. After `Core.migrate`, anyone calls the old module's `migrateReserve()`; verify old and new holdings and the `ReserveMigrated` event. Repeat for statements redeemed by the old Core afterwards. The transfer succeeds once upstream retirement is complete and the opening block is reached. Resolve old-token reserves before locking the successor to a different currency. Binding getters do not authenticate code: verify the successor and its module before selecting them. This procedure is separate from the ETH and Credits migration.

`test/UpstreamBalance.t.sol` runs Jack's contract from a locally prepared artifact (`python3 script/prepare-upstream-balance.py <credits checkout>`). The candidate workflow prepares it and sets `REQUIRE_UPSTREAM_BALANCE=true` when the repository secret `UPSTREAM_CREDITS_TOKEN` (read access to the upstream repository) is set. Without the secret the frozen-candidate run executes it locally with `REQUIRE_UPSTREAM_BALANCE=true`. Either way the result is recorded as an `upstream balance` row of the freeze table (docs/STATUS.md section 4). Every other run skips it when the artifact is absent.
