# runbook

the launch, the owner commands after it, and what to do when something stops half way. the rules are docs/SPEC.md. every number here comes from the code, the config or the latest rehearsal record (docs/reviews/REHEARSAL-<candidate>.md, named by the freeze table in docs/STATUS.md). the owner sends every mainnet transaction; the owner address is an EIP 7702 delegated account, so every multi transaction broadcast uses `--slow`.

## 0. what you need

| item | note |
|---|---|
| the live v2 stack | the five stack addresses are in the tracked script/config/mainnet.json (factory 0x9b17bf6f97F5429368E11028BC637479b4667f7b); the recorded stack with its code hashes is script/config/v2-mainnet.json, pinned by preflight |
| the signer | one key does every transaction: the v2 factory owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9, also the config `owner` and `creator`, the Core owner and the payee. `deployTokenAsOwner` is owner only. sign with `--ledger` or `--account <name>`; `--private-key $PRIVATE_KEY` only on a throwaway fork |
| eth | the deploy fee (0.069 eth at the pin, read live) plus gas for nine transactions, 16,120,826 gas measured at block 26186912: 0.085 eth at 1 gwei, 0.150 at 5 gwei, 0.391 at 20 gwei, fee included. fund about 20 percent over the figure for the expected base fee |
| read rpc | an archive capable mainnet rpc in `MAINNET_RPC_URL`, for every command that does not send |
| private rpc | `PRIVATE_RPC`, a relay that does not publish to the public mempool and serves `eth_getCode`, `eth_getStorageAt` and `eth_call` (https://rpc.mevblocker.io did when tested) |
| etherscan key | `ETHERSCAN_API_KEY` for verification |
| the toolchain | foundry 1.8.1, solc 0.8.30. `forge build` rewrites foundry.lock and lib/solady: `git checkout foundry.lock; git submodule update -- lib/solady` before any commit or gate |

## 1. the launch, commands in order

| step | action | command or note |
|---|---|---|
| 1 | local config | `cp script/config/mainnet.json script/config/local.json` (gitignored). fill `image` (at most 2048 bytes, with a scheme) and `description` (at most 4096 bytes). set `rateStart` to the market price of one credit on launch day in wei and `rateCap` to 3 times it (preflight checks the ratio). set `credit.royaltyRecipient` to the artist's address (the tracked file holds the owner as a placeholder). review every value against docs/SPEC.md section 3 |
| 2 | rehearse | `REHEARSAL=1 LAUNCH_CONFIG=script/config/local.json forge test --match-path test/Rehearsal.t.sol -vv`: a fork of the latest block, the owner command, the whole deploy, postflight and a trading smoke. it prints the gas of each transaction and the eth the owner needs at 1, 5 and 20 gwei. the addresses it prints are the CREATE2 addresses the launch will use |
| 3 | owner command on the factory | the factory's minimum protocol skim share is 1,000 and the launch needs at most 362: `cast send $FACTORY "setMinProtocolSkimShareBps(uint16)" 362 --rpc-url $MAINNET_RPC_URL --ledger`, confirm with `cast call $FACTORY "minProtocolSkimShareBps()(uint16)"`. after step 6, set it back to 1,000 in its own transaction |
| 4 | preflight and sign off | `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL \| grep -E '^ +(WARN\|FAIL\|[0-9]+ of\|CONFIG_HASH\|signoff)'`. 116 rows, every one ok (WARN rows never fail). read the `signoff:` rows. `export CONFIG_HASH=0x...` from the printed value |
| 5 | dry run | `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. simulates every transaction, runs preflight first and postflight on the result; nothing is sent. the balance row of the dry run reads high; the funding check is step 4's row and a direct `cast balance $DEPLOYER` |
| 6 | broadcast | `git checkout foundry.lock; git submodule update -- lib/solady`, then `script/tools/check-freeze.sh` from the candidate commit (every row of the freeze table ok, exit 0), then `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger`. note the printed addresses: `export CORE=... COIN=... CONTROLLER=...`. then the set back of step 3 |
| 7 | verify | section 3 |
| 8 | postflight | `CORE=$CORE DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. 70 rows, every one ok; the locked recipients row is a WARN until `lockRecipients`. record the start tick it prints and the date as the launch price |
| 9 | the window's end | 30 minutes after the launch block: `cast send $CORE "book()" --rpc-url $MAINNET_RPC_URL --ledger` (anyone may send it). it latches the payee share; fees that arrive between the window's end and this call are not shared |
| 10 | later owner decisions | `lockRecipients` (with `lockSuccessor`), `lockAllowlist`, the balance side, the credit sale, chosen composition: section 4 |

the nine transactions of step 6, in order: the library `CoreLib`, the Core, the controller, the Seaport adapter, the CreditStrategy adapter, `setController`, `addAdapter` twice, `deployTokenAsOwner` with the fee. all but the launch go through the deterministic deployer (CREATE2) at addresses that depend on the config and the salts; a contract with code at its address is skipped, so a stopped run continues from the chain (section 6).

what the scripts refuse: `Deploy` and `Resume` refuse an unset placeholder, a value out of bounds, a `CONFIG_HASH` that is not the hash of the loaded config, a signer that is not the factory owner, and the flags `SETTINGS_CHANGED` or `COIN_CHANGED` in the environment (each turns failed postflight rows into warnings after an owner change; only `Postflight` honors them).

## 2. the sign off table

preflight prints a `signoff:` row for each block below; the owner confirms each against docs/SPEC.md section 3 before step 6.

| block | rows |
|---|---|
| the bid | `rateStart` (market price of a credit, wei), `rateCap` (3 times it), the nine bid settings |
| the sale | `saleFloorBps` 10,000, `saleToBuybackBps` 5,000, the `Sale` struct (markup 15,000, cap 100,000, fast 100, knee 10,000, slow 25, anchor half life 604,800, anchor min cost 0.1 eth) |
| the credit side | `creditCostToPotBps` 10,000, `chosenComposeOn` false, `minCcToChoose` 1e18, `saleOn` false, `window` 14,400, `floorBps` 11,000, `startBps` 30,000, `refScore` 4,330,000, `royaltyBps` 250, `royaltyRecipient` |
| the balance side | `redeemOn` false, `balanceBidOn` false, `redeemSlippageBps` 200, `balanceBidMarginBps` 2,000, `redeemBurnBps` 2,000, `feeToRedeemBurnBps` 1,000 |
| the keepers | `buybackSlice` 0.5 eth, `buybackDelay` 25, `keeperFee` 0.0005 eth, `keeperMaxBaseFee` 10 gwei, `callerFee` 0, `callerMaxBaseFee` 0 |
| the payee | `payee` the owner, `payeePpm` 75,185 (0.5 points of volume) |
| the adapters | the Seaport recipient allowlist (the OpenSea fee collector 0x0000a26b00c1F0DF003000390027140000fAa719) |
| the coin | name CC, symbol CC, supply 1e27, start tick -175000, position -175000 to 887200, skim 690 bps, bounty 9,638, lp fee 0, sniper 9,000 bps over 1,800 s, protocol 2,000 bps, restricted, allowlist empty, image, description |
| the build | the masked runtime code hashes of the five contracts and the library creation hash |

## 3. verify on etherscan

after step 6, for each of the Core, the controller, the two adapters and the library: `forge verify-contract <address> <path>:<name> --chain 1 --etherscan-api-key $ETHERSCAN_API_KEY --constructor-args <args> --libraries src/lib/CoreLib.sol:CoreLib:$LIB` where postflight prints the constructor args of the Core and the controller and `LIB` is the library address from `broadcast/Deploy.s.sol/1/run-latest.json`. the compiler settings are foundry.toml's (solc 0.8.30, via_ir, optimizer 200).

## 4. after the launch

### owner commands

all by the owner, effective at once. the settings scripts dry run unless `SEND=1` and `--broadcast`.

| what | how |
|---|---|
| a Core setting | `script/SetSettings.s.sol`: `SET_<field>=<value>` for each changed field, `SET_RATE=<wei>` for `setRate`; with `CONTROLLER=$CONTROLLER` it drives `setSale` and `setCredit`. one call sets the whole struct, so set every field you mean |
| pause and resume | `cast send $CORE "setPaused(bool)" true` and `false` |
| the payee | `cast send $CORE "setPayee(address)" <to>`; anyone can `claimPayee()` |
| the adapters | `addAdapter(address)`, `removeAdapter(address)`, `lockAdapters()`; on the Seaport adapter `setAllowedRecipient(address,bool)`. in the first days watch `buyListing` reverts for `RecipientNotAllowed` and add the recipient that Credits listings carry |
| the credit sale window | `setCredit` with `saleOn` true; read `creditPrice(id)` back |
| chosen composition | `setChosenComposeOn(bool)`, `setMinCcToChoose(uint96)` (also the gate of `setHeldFormat`) |
| the balance side | once the balance module is written and verified: `setBalanceModule(address)` (replaceable until `lockBalanceModule()`), then `setSettings` with `redeemOn` and `balanceBidOn`, then on the controller `setBalancePoolKey((address,address,uint24,int24,address))` with native eth as currency0 and the balance token as currency1 once its pool is live. when the balance token's auction is announced: `setPaused(true)`, reprice with the live settings, `setPaused(false)` |
| the reserve | `releaseRedeemBurn(uint256)` moves reserve eth into the buyback pot |
| composing | `compose()`, `compose(uint8)` or `composeChosen` when nobody else does; switch the payment on with `callerFee` and `callerMaxBaseFee` if pages sit |
| the coin | `coin.lockRecipients()` (script/Lock.s.sol: postflight, then the lock) seals the bounty recipient and ends fee stream migration; take it together with `lockSuccessor`. `lockAllowlist()`, `unrestrict()`, `renounceAdmin()`, `setMetadataRenderer`, `updateImage`, `updateDescription` are the coin admin's |

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
3. `setSuccessor(successor)` on the old Core, then dry run `migrate` on a fork (`cast call $CORE "migrate(uint256)" 150 --from $OWNER`), then `migrate(150)` repeatedly until `ethPot`, `balancePot` and the pile are 0 (about 44,800 gas per credit; 370 is the largest batch under the cap). the first call retires the old engine.
4. on the successor: `adopt` the credits it received, `bookBalance()` once its module is set. the old engine keeps selling and redeeming its statements and burning its buyback pot.

### keeper duties

| duty | call | paid |
|---|---|---|
| sweep a listing below the bid | `buyListing(adapter, id, params)` | gas at the base fee up to 10 gwei plus 0.0005 eth, at most the gap |
| burn | `buyback()` every 25 blocks while the buyback pot holds at least twice the largest payment | gas plus the scaled fee |
| compose | `compose()` when `nextPage()` is ready | 0 until the owner switches the payment on |
| redeem | `redeemStatement(sid)` when `atFloor(sid)` and `redeemOn` | 0 until switched on |
| book | `book()` at the window's end, `collectEscrow()` if the escrow holds a credit for the Core | nothing |

### a dump that walks the bid down, and statements above the floor

the bid recovers at 2 percent a minute below the remembered peak and 0.5 percent above it; a one minute dump of 140 credits is back in about an hour. `setRate` restates the bid and the peak at once if the owner wants it faster. statements bought above market sit at their reference until the market reaches it or the balance side opens; lower `saleFloorBps` to sell them below cost, which reaches every held statement at once.

### watching the buyback after a price fall

the 0.5 eth slice is unprofitable to sandwich down to about a quarter of the launch pool depth (about 94 percent below the launch price). read the pool tick weekly against the launch record; past a 90 percent fall set `buybackSlice` to 0.2 eth, past 98 percent to 0.1 eth.

## 5. what cannot change after the launch

the skim (6.9 points), the bounty split (9,638 of 10,000), the protocol recipient, the ticks and the supply are fixed in the pool and the coin. the Core's stack, coin, `RATE_START` and `SNIPER_SECONDS` are immutables; a new stack or a new coin is a new Core. everything in docs/SPEC.md section 3 is adjustable.

## 6. when a transaction fails half way

every state between the nine transactions is safe: the library is stateless, the controller and the adapters are inert until the Core points at them, and a Core without a controller holds nothing and refuses its controller doors. nobody else can launch the predicted coin, because `deployTokenAsOwner` is owner only.

```sh
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12     # 0x... means the Core exists
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12     # 0x means the launch is not sent
```

| state | recovery |
|---|---|
| nothing or only the library sent | rerun `Deploy`; what has code is skipped |
| the Core sent, the launch not | `CORE=$CORE DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger`: creates what has no code, sends the owner calls and the launch that are missing, runs postflight. it refuses a `CORE` that is not this config's address (`CoreMismatch`), no Core (`NotStarted`), a launched coin (`AlreadyLaunched`) |
| launched | `Postflight`, then step 9 |

## 7. local end to end

an anvil fork of block 26158000 (chain id 31337) with the system deployed by the launch scripts, a seed and a scenario that fires every user and keeper door. the web app reads the record `deployments/31337.json` (gitignored).

| item | how |
|---|---|
| start the chain | `script/dev/local.sh` leaves anvil running on port 8545 (`PORT=` changes it). the first run builds the state with `script/dev/e2e.sh` (about 5 minutes, most of it the seed's credit transfers) and saves it under `script/dev/.cache/`; a later run with unchanged src, script, test/standins and test/utils loads the saved state in seconds. `FRESH=1` rebuilds, `script/dev/local.sh stop` stops anvil |
| the run itself | `script/dev/e2e.sh` starts its own anvil, runs everything and stops it. `KEEP=1` leaves anvil running, `STOP_AFTER=<stage>` stops after a stage, `NO_ANVIL=1` and `E2E_RPC_URL` reuse a node. `FORK_URL` is the archive rpc, the Tenderly public gateway by default |
| deploy | `script/deploy.sh local` funds the factory owner, lowers `minProtocolSkimShareBps` to 362 and restores it, then runs Preflight, Deploy (`--unlocked --broadcast --slow`) and Postflight. the scripts require chain id 1, so forge runs with `--chain-id 1` |
| phase `pre` | the credits move to three accounts (`script/dev/Seed.s.sol`); the balance side, the credit sale and chosen composition start off |
| phase `post` (default) | the seed also deploys `MockBalanceToken` and `MockBalanceModule` (which mints `rating * unit` on redeem), mints the token to the Core, creates an eth / balance pool at the config's `dev.balancePoolSqrtPriceX96` with full range liquidity from the trader, then as owner sets the module, books the balance, switches `redeemOn`, `balanceBidOn`, the credit sale and chosen composition on, and sets the controller's pool key |
| stages | `script/dev/Scenario.s.sol`, one `STAGE` per forge run: `a` (coin trades, `book`, payee latch), `fill-a` (`sellForEth` both forms), `adopt`, `compose-a` (`compose()`, `buy` at `grossPriceOf`), `claims` (`claimRoyalty`, `claimPayee`), `d-open`, `d-buy` (`buyCredit`, `buyCredits`), `fill-b`, `compose-b` (`composeChosen`), `format` (`setHeldFormat`), `settings` (`setSale`, `setCredit`, `setRate`, `setSettings`, `fund`), `pause`, `buyback`; in `post` also `fill-d`, `compose-d` (`compose(uint8)`), `redeem` (`redeemStatement`, `releaseRedeemBurn`), `balance-bid` (`sellForBalance` both forms); then `fresh-fill`, `fresh-compose`, `report`. node time warps run between the stages |
| the record | `chainId`, `rpcUrl`, `deployBlock`, the five contracts and the library, the live Credits, Statements, pool manager and hook, `poolFee`, `tickSpacing`, `owner`, `accounts` (a1, a2, a3, keeper, trader), `phase`, and in `post` `balanceToken`, `balanceModule` and `balancePool` (`null` in `pre`) |

`buyListing` is outside the scenario: the CreditStrategy lists at about four times the rate cap and the Seaport adapter prices an order that needs an external signature.
