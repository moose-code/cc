# runbook

the launch, the owner commands after it, and what to do when something stops half way. the rules are docs/SPEC.md. every number here comes from the code, the config or the latest rehearsal record (docs/reviews/REHEARSAL-<candidate>.md, named by the freeze table in docs/STATUS.md). the owner sends every mainnet transaction; the owner address is an EIP 7702 delegated account, so every multi transaction broadcast uses `--slow`.

## 0. what you need

| item | note |
|---|---|
| the live v2 stack | the five stack addresses are in the tracked script/config/mainnet.json (factory 0x9b17bf6f97F5429368E11028BC637479b4667f7b); the recorded stack with its code hashes is script/config/v2-mainnet.json, pinned by preflight |
| the signer | one key does every transaction: the v2 factory owner 0xCB43078C32423F5348Cab5885911C3B5faE217F9, also the config `owner` and `creator`, the Core owner and the payee. `deployToken` is owner only on the deprecated factory. sign with `--ledger` or `--account <name>`; `--private-key $PRIVATE_KEY` only on a throwaway fork |
| eth | the deploy fee (0.069 eth at the pin, read live) plus gas for eleven transactions, 19,069,638 gas measured on the master stack fixture: 0.088 eth at 1 gwei, 0.164 at 5 gwei, 0.450 at 20 gwei, fee included. fund about 20 percent over the figure for the expected base fee |
| read rpc | an archive capable mainnet rpc in `MAINNET_RPC_URL`, for every command that does not send |
| private rpc | `PRIVATE_RPC`, a relay that does not publish to the public mempool and serves `eth_getCode`, `eth_getStorageAt` and `eth_call` (https://rpc.mevblocker.io did when tested) |
| etherscan key | `ETHERSCAN_API_KEY` for verification |
| the toolchain | foundry 1.8.1, solc 0.8.30. `forge build` rewrites foundry.lock and lib/solady: `git checkout foundry.lock; git submodule update -- lib/solady` before any commit or gate |

## 1. the launch, commands in order

| step | action | command or note |
|---|---|---|
| 1 | local config | `cp script/config/mainnet.json script/config/local.json` (gitignored). `image` (at most 2048 bytes, with a scheme) and `description` (at most 4096 bytes) may stay empty: the coin renderer draws the image and reads the description from the coin, so `description` is the coin's description text. a renderer is bound to one Core: after a launch attempt that created the renderer, a config change that moves the Core address needs a new `salt`, and preflight fails `predicted renderer is empty` until then. set `rateStart` to the market price on launch day of a credit of score `settings.refScore` (4,330,000, the launch average) in wei and `rateCap` to 3 times it (preflight checks the ratio). set `artist` to the artist's address (the tracked file holds the decided launch address). review every value against docs/SPEC.md section 3 |
| 2 | rehearse | `REHEARSAL=1 LAUNCH_CONFIG=script/config/local.json forge test --match-path test/Rehearsal.t.sol -vv`: a fork of the latest block, the owner command, the whole deploy, postflight and a trading smoke. it prints the gas of each transaction and the eth the owner needs at 1, 5 and 20 gwei. the addresses it prints are the CREATE2 addresses the launch will use |
| 3 | owner command on the factory | the factory's minimum protocol skim share is 1,000 and the launch needs at most 1000: `cast send $FACTORY "setMinProtocolSkimShareBps(uint16)" 1000 --rpc-url $MAINNET_RPC_URL --ledger`, confirm with `cast call $FACTORY "minProtocolSkimShareBps()(uint16)"`. after step 6, set it back to 1,000 in its own transaction |
| 4 | preflight and sign off | `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL \| grep -E '^ +(WARN\|FAIL\|[0-9]+ of\|CONFIG_HASH\|signoff)'`. 118 rows, every one ok (WARN rows never fail). read the `signoff:` rows. `export CONFIG_HASH=0x...` from the printed value |
| 5 | dry run | `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. simulates every transaction, runs preflight first and postflight on the result; nothing is sent. the balance row of the dry run reads high; the funding check is step 4's row and a direct `cast balance $DEPLOYER` |
| 6 | broadcast | `git checkout foundry.lock; git submodule update -- lib/solady`, then `script/tools/check-freeze.sh` from the candidate commit (every row of the freeze table ok, exit 0), then `DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger`. note the printed addresses: `export CORE=... COIN=... CONTROLLER=... RENDERER=...`. then the set back of step 3 |
| 7 | verify | section 3 |
| 8 | postflight | `CORE=$CORE DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. 73 rows, every one ok; the locked recipients row is a WARN until `lockRecipients`. record the start tick it prints and the date as the launch price |
| 9 | the window's end | 30 minutes after the launch block: `cast send $CORE "book()" --rpc-url $MAINNET_RPC_URL --ledger` (anyone may send it). it latches the payee share; fees that arrive between the window's end and this call are not shared |
| 10 | later owner decisions | `lockRecipients` (with `lockSuccessor`), `lockAllowlist`, the balance side, the credit sale, chosen composition: section 4 |

the eleven transactions of step 6, in order: the library `CoreLib`, the Core, the controller, the Seaport adapter, the CreditStrategy adapter, the coin renderer `CoinRenderer` (constructed with the config owner), `setCore` on the renderer (binds the Core, once), `setController`, `addAdapter` twice, `deployToken` with the fee, which names the renderer in the token config. the creations go through the deterministic deployer (CREATE2) at addresses that depend on the config and the salts; a contract with code at its address is skipped and a call whose effect is on chain is skipped, so a stopped run continues from the chain (section 6).

what the scripts refuse: `Deploy` and `Resume` refuse an unset placeholder, a value out of bounds, a `CONFIG_HASH` that is not the hash of the loaded config, a signer that is not the factory owner, and the flags `SETTINGS_CHANGED` or `COIN_CHANGED` in the environment (each turns failed postflight rows into warnings after an owner change; only `Postflight` honors them).

## 2. the sign off table

preflight prints a `signoff:` row for each block below; the owner confirms each against docs/SPEC.md section 3 before step 6.

| block | rows |
|---|---|
| the bid | `rateStart` (market price on launch day of a credit of score `refScore`, wei), `rateCap` (3 times it), `refScore` 4,330,000 (the launch average credit score), the nine bid settings |
| the sale | `saleFloorBps` 10,000, `saleToBuybackBps` 2,500, the `Sale` struct (markup 15,000, cap 100,000, decay hours 12, anchor half life 604,800, anchor min cost 0.1 eth) |
| the credit side | `creditCostToPotBps` 8,000, `chosenComposeOn` false, `minCcToChoose` 1e18, `saleOn` true, `window` 14,400, `floorBps` 11,000, `startBps` 30,000 (`refScore` is a bid setting above) |
| the credit swap | `swapFeeCc` 10,000e18 (ten thousand coins burned per `swapCredit`) |
| the balance side | `redeemOn` true, `balanceBidOn` false, `redeemSlippageBps` 200, `balanceBidMarginBps` 1,000, `redeemBurnBps` 2,000, `feeToRedeemBurnBps` 1,000 |
| the keepers | `buybackSlice` 0.5 eth, `buybackDelay` 25, `keeperFee` 0.0003 eth, `keeperMaxBaseFee` 5 gwei, `callerFee` 0, `callerMaxBaseFee` 0 |
| the payee and the artist | `payee` the owner, `payeePpm` 0 at launch (the owner raises it later); `artist` the launch artist address; the nft sale cuts `saleToArtistBps` 250, `saleToOperatorBps` 50 |
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
| a Core setting | `script/SetSettings.s.sol`: `SET_<field>=<value>` for each changed field, `SET_RATE=<wei>` for `setRate`; with `CONTROLLER=$CONTROLLER` it drives `setSale` and `setCredit`. one call sets the whole struct, so set every field you mean |
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
| sweep a listing below the bid | `buyListing(adapter, id, params)` | gas at the base fee up to 5 gwei plus 0.0003 eth, at most the gap |
| burn | `buyback()` every 25 blocks while the buyback pot holds at least twice the largest payment | gas plus the scaled fee |
| compose | `compose()` when `nextPage()` is ready | 0 until the owner switches the payment on |
| redeem | `redeemStatement(sid)` when `atFloor(sid)` and `redeemOn` | 0; reverts `NoBalanceModule` until the module is set |
| book | `book()` at the window's end, `collectEscrow()` if the escrow holds a credit for the Core | nothing |

### a dump that walks the bid down, and statements above the floor

the bid recovers at 2 percent a minute below the remembered peak and 0.5 percent above it; a one minute dump of 140 credits is back in about an hour. `setRate` restates the bid and the peak at once if the owner wants it faster. statements bought above market sit at their reference until the market reaches it or the balance side opens; lower `saleFloorBps` to sell them below cost, which reaches every held statement at once.

### watching the buyback after a price fall

the 0.5 eth slice is unprofitable to sandwich down to about a quarter of the launch pool depth (about 94 percent below the launch price). read the pool tick weekly against the launch record; past a 90 percent fall set `buybackSlice` to 0.2 eth, past 98 percent to 0.1 eth.

## 5. what cannot change after the launch

the skim (10 points), the bounty split (9,000 of 10,000), the protocol recipient, the ticks and the supply are fixed in the pool and the coin. the Core's stack, coin, `RATE_START` and `SNIPER_SECONDS` are immutables; a new stack or a new coin is a new Core. everything in docs/SPEC.md section 3 is adjustable.

## 6. when a transaction fails half way

every state between the eleven transactions is safe: the library is stateless, the controller and the adapters are inert until the Core points at them, and a Core without a controller holds nothing and refuses its controller doors. nobody else can launch the predicted coin, because `deployToken` is owner only on the deprecated factory.

```sh
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12     # 0x... means the Core exists
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12     # 0x means the launch is not sent
```

| state | recovery |
|---|---|
| nothing or only the library sent | rerun `Deploy`; what has code is skipped |
| the Core sent, the launch not | `CORE=$CORE DEPLOYER=$DEPLOYER LAUNCH_CONFIG=script/config/local.json CONFIG_HASH=$CONFIG_HASH forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger`: creates what has no code, sends the renderer, `setCore`, the owner calls and the launch that are missing, runs postflight. it refuses a `CORE` that is not this config's address (`CoreMismatch`), no Core (`NotStarted`), a launched coin (`AlreadyLaunched`) |
| launched | `Postflight`, then step 9 |

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

The dump is anvil_dumpState gzip hex, loadable through the `anvil_loadState` rpc, not `anvil --load-state`. `STACK=master script/dev/anvil.sh` forks at chain id 31337 and loads the state after startup; the engine's forge scripts re-enter chain id 1 with `--chain-id 1` and the test suite runs with `--chain-id 1`.
