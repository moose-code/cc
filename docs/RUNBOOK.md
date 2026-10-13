# deploy runbook

this is the launch runbook for branch `main`, on the artcoins v2 stack, live on mainnet since 2026-10-09 (contract sources of v2 repo commit d4aa46b, deployed from launcher commit fbe07c7). the stack is a config input: the `stack` block of `script/config/mainnet.json` holds the five v2 addresses the Core takes as a constructor argument, and nothing in `src/` hardcodes an artcoins address. `Deploy` refuses a file that leaves a stack address at zero.

### the live v2 stack

`script/config/v2-mainnet.json` is the record of the artcoins v2 stack on mainnet: the ten contract addresses, their deploy blocks, the launcher commit it was deployed from (fbe07c7, contract sources of d4aa46b) and the salt of the hook CREATE2 deployment. `test/utils/V2Stack.sol` reads the addresses from it, and a test requires the `stack` block of `script/config/mainnet.json` to equal it.

| contract | address | deploy block |
|---|---|---|
| factory `ArtCoinsFactoryV2` | 0x9b17bf6f97F5429368E11028BC637479b4667f7b | 26157200 |
| hook `ArtCoinsHookV2` (CREATE2, deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C, salt 0x5544, low bits 0x28CC) | 0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc | 26157197 |
| locker `ArtCoinsLpLockerV2` | 0x1e2456861B864B96FFe6b34066b12FBD7EEb23fC | 26157198 |
| fee escrow `ArtCoinsFeeEscrowV2` | 0x32845df52436a737C9623Af1d461A1c9999BBc1e | 26157195 |
| mev module `ArtCoinsMevLinearSkimV2` | 0xFbb55b4C13b8517C000e2686efB12F0FAAFc9072 | 26157199 |
| token deployer `ArtCoinsDeployerV2` | 0xB2f0086E6EE82f059AD1736dD265a783cE50f473 | 26157201 |
| extension allowlist `ArtCoinsPoolExtensionAllowlist` | 0xddbC9EE6A8E08b4afC208B9dD1f283506E669C11 | 26157196 |
| burn router `BurnRouterV2` | 0x6f159a0BDddB808Ca364cd006fb29C7B52eB88e1 | 26157203 |
| protocol fee controller `ProtocolFeeControllerV2` | 0x183De82db1b7AAb798328AB1d7AE181ff39460c2 | 26157204 |
| keeper `ArtCoinsKeeperV2` | 0x9884B79974a51aaa07b3a7f0B45b6Ae294FC7072 | 26157205 |

the owner of the factory, hook, locker, escrow, allowlist, burn router and controller is 0xCB43078C32423F5348Cab5885911C3B5faE217F9 (the factory, hook, locker and escrow have no pending owner). the last transaction of the stack wiring is in block 26157222. the factory state is `deprecated`: only the owner launches, through `deployTokenAsOwner`. `minProtocolSkimShareBps` is 1,000 (step 3 lowers it to 362), `deployFee` 0.069 eth, `defaultProtocolFeeBps` 2,000, `teamFeeRecipient` the owner, `defaultAllowed` empty.

the owner address carries an EIP 7702 delegation (its code is 0xef0100 followed by the delegate address). the launch pays the deploy fee to it as team fee recipient, and the fork tests exercise that transfer through the live factory. a broadcast from it with more than one transaction needs `--slow` (step 6 has it).

the fork tests pin block 26158000 (`FORK_BLOCK` in `.env.example`, 2026-10-09 22:59:59 UTC). every code hash of the pin table below was read at that block.

the pin table is informational. preflight checks the `V2_CODEHASH_*` constants in `script/LaunchConfig.sol`, and `test_preflightPinsTheLiveCodeHashes` ties each constant to the code on chain at the fork block.

| code hash pin | `extcodehash` |
|---|---|
| hook | 0xdfd4453028eb0f5176cd00fdbbeb495e75754cef9fd36091767cdb593449562b |
| factory | 0x521076a0cde91c74a1c3a72f676818dd423d125647a5e038531443a86a9a9156 |
| locker | 0xc0d3e2539d75cdaf225bd64266bfd3e6ee7c602abfd173f59dd04fc43195eaad |
| fee escrow | 0x2f88e4ff28749a58a6710c291c1a17d05dd099b6da1289acf6116182c0c673a4 |
| mev module | 0x5b513087e1c593a3d8a3932a9a768491658eadee76941502d2351a7081a3581b |
| token deployer | 0xa1ea224b73bee06c71738152d536147b9845ccd2969070ba01c01904670fbd98 |
| extension allowlist | 0x7a98bacb16f0ec968f5d450c37e6a5a4ef213a8d48c61c666b2cea3e0f6318c4 |
| protocol fee controller | 0x8c3e7bdfc124978e815095822a16b9f0c5fbd1f4925b99eaedeed542b5ca3feb |
| burn router | 0x937f1a92e636aed39eb430bd3be2882201479768a84f5c253f3788114f4574fb |

preflight reads the hash of each contract the config and the factory point at (the token deployer and the protocol recipient from the factory, the allowlist from the hook, the burn router from the controller) and fails any difference from the constants `V2_CODEHASH_*` in `script/LaunchConfig.sol`. the nine hashes are the same at block 26158000 and at the latest block of 2026-10-09 (26158354). the keeper is outside the launch path and has no pin.

the deprecated rule, from `ArtCoinsFactoryV2._launch`: while `deprecated` is true the first statement reverts `Deprecated()` for every caller except `owner()`. `deployTokenAsOwner` is `onlyOwner` and reaches `_launch`, so the owner launches while the factory is deprecated and `deployToken` by any other caller reverts. preflight states the rule in the row `factory: deprecated, the owner launches and any other caller reverts Deprecated()`: it sends `deployToken` from a stranger on a snapshot and requires the `Deprecated()` revert, and the row `factory: deployTokenAsOwner accepts the config (simulated)` is the owner half.

naming rule: the vocabulary is "balance", never "exit" (decision 102). code, comments, tests and docs name the balance side contracts `balanceModule` and `balanceToken`.

## 0. what you need

| item | note |
|---|---|
| v2 on mainnet | live (section "the live v2 stack" above). the five stack addresses are in the tracked `script/config/mainnet.json`. the rehearsal (`REHEARSAL=1`) forks the latest block and launches through the live factory with the owner impersonated |
| the signer | one key does every transaction: the v2 factory owner, 0xCB43078C32423F5348Cab5885911C3B5faE217F9 (the latest rehearsal record, `docs/reviews/REHEARSAL-<candidate>.md` for the candidate row of the freeze table in `docs/STATUS.md`, lists the balance read at its block, the nonce and the need at the base fee of that block). the launch needs the deploy fee of 0.069 eth plus gas for ten transactions. the record lists the owner funding needed at 1, 5 and 20 gwei, and preflight fails the balance row while the balance is below the need. the funding check of step 5 is a direct balance read. the signer is also the config `owner` and `creator`, the Core owner. `deployTokenAsOwner` is owner only, so there is no fresh deployer, no factory admin enable and no revoke. sign with `--ledger` or `--account <name>`, or `--private-key $PRIVATE_KEY` for a throwaway fork. `Deploy` and `Resume` refuse any other signer (`NotFactoryOwner`, `DeployerMismatch`) |
| eth | the factory deploy fee (read live, 0.069 eth at the pin, sent as the value of the launch) plus gas for ten transactions. the ten transactions are the library, the core, the controller, the lens, the Seaport adapter, the CreditStrategy adapter, `setController`, `addAdapter` for each of the two adapters and the launch. the rehearsal (`REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`) measures the gas of each (the execution gas plus the intrinsic 21,000, the calldata and, for a creation, the code deposit), prints the table for the latest block and asserts that the total stays under `DEPLOY_GAS_ESTIMATE` (22,100,000, the measured 19,175,291 plus 15 percent), which preflight multiplies by the base fee and adds to the fee for the balance row. the latest rehearsal record lists the gas per transaction, the total, the owner funding needed at 1, 5 and 20 gwei and the base fee up to which the owner balance of that record covers the fee plus the gas. fund the key about 20 percent over the funding figure for the expected base fee |
| read rpc | any archive capable mainnet rpc, in `MAINNET_RPC_URL`. used by every command that does not send |
| private rpc | `PRIVATE_RPC`, a relay that does not publish to the public mempool and still serves state reads. `forge script --broadcast` forks the rpc it sends through, so it needs `eth_getCode`, `eth_getStorageAt` and `eth_call`. `https://rpc.mevblocker.io` served them when tested (2026 10 05), the Flashbots Protect endpoint did not. test it, below |
| etherscan key | `ETHERSCAN_API_KEY`, for verification |

with the owner as the only sender, a public mempool is not a safety problem. the v2 owner path cannot be copied by anyone else, so the relay protects secrecy only: a watcher can read the config from the pending launch and prepare to trade in the launch block. the anti sniper skim starts at 90 points of volume and falls to the baseline over 30 minutes, the extra above the baseline goes to the bounty recipient (the Core, which shares none of the window with the payee), so being first costs the buyer.

a fresh clone has no `.env`: create it from `.env.example` and fill it before the next command. shell variables used below, set once after `set -a; . ./.env; set +a`:

```sh
export PRIVATE_RPC=https://rpc.mevblocker.io
export LAUNCH_CONFIG=script/config/local.json   # step 1, gitignored
export FACTORY=$(jq -r .stack.factory $LAUNCH_CONFIG)
export OWNER=$(jq -r .owner $LAUNCH_CONFIG)     # the factory owner, the signer
export DEPLOYER=$OWNER                          # Deploy and Resume refuse a signer that is another address
# set later: CONFIG_HASH (step 4), CORE, COIN, CONTROLLER, LENS, LIB (step 6)
```

the signer comes from the command line flags only (`--ledger`, `--account`, `--private-key`). no environment variable picks a signer, so a stray `PRIVATE_KEY` in `.env` cannot override a ledger.

test the private rpc before step 6:

```sh
cast code $FACTORY --rpc-url $PRIVATE_RPC | head -c 20       # must print code starting 0x60 (0x60c0 on the live factory), not an error
cast call $FACTORY "owner()(address)" --rpc-url $PRIVATE_RPC   # must print the owner
```

if either errors, use a normal rpc for step 6. nothing else changes: the exposure is only that the config is readable before it mines.

## 1. commands in order

all commands run from the repo root. read commands use `$MAINNET_RPC_URL`, the one broadcast uses `$PRIVATE_RPC`. the dry form of `Resume` drops `--broadcast` and `--ledger` and takes `--sender $DEPLOYER`. `Postflight` and `Lock` need only the rpc. do not run `forge clean` before the launch: a cold via_ir rebuild takes minutes and can change the build pins, and forge's notice about artifacts built from deleted sources is harmless.

| step | action | command or owner |
|---|---|---|
| 1 | local config | `cp script/config/mainnet.json script/config/local.json` (gitignored, never edit the tracked file). the five v2 addresses in `stack` are filled in the tracked file, set `rateStart` by the launch day rule below, review every row of section 2. `owner`, `creator`, `name`, `symbol` and `salt` are filled in the tracked file, change `salt` only when the predicted coin address is taken. `image` (the image url, at most 2048 bytes) and `description` (at most 4096 bytes) are strings in the config, empty in the tracked file. the owner fills both before step 4. they go to the factory in the launch transaction, are part of `CONFIG_HASH`, and are inputs of the predicted coin address (a changed string moves the address, preflight recomputes it). on chain id 1 the row `rule: image and description are filled and are not placeholders` fails while either is blank after trimming (spaces, tabs, newlines, NBSP), contains `placeholder` in any letter case, is `todo` or `tbd` as the whole value, or while `image` does not start with a lowercase `ipfs://`, `https://`, `ar://` or `data:` scheme with content past it and no surrounding whitespace, and the launch uses the real values. the image goes on chain exactly as written, so write the scheme in lower case with no leading or trailing whitespace. the rehearsal reads `script/config/rehearsal.json` when `LAUNCH_CONFIG` is unset, a copy of `mainnet.json` whose `image` and `description` hold the marker, and expects this row to fail in both of its preflight assertions. the launch uses `mainnet.json` (or a `local.json` copied from it) with the real values filled in; the row fails until they are. the coin admin can change both afterwards (section 4, the coin's metadata). `export LAUNCH_CONFIG=script/config/local.json`. `LAUNCH_CONFIG` must be a path inside the project tree: a file elsewhere (for example in /private/tmp) fails with `vm.readFile ... not allowed` (`fs_permissions`) |
| 2 | rehearse the exact file | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`. it reads `LAUNCH_CONFIG` (default `script/config/rehearsal.json`; pass `LAUNCH_CONFIG=script/config/local.json` to rehearse the file with the real metadata, where every preflight row must pass), launches through the live v2 factory on a fork of the latest block (a file that leaves the stack at zero gets the live stack of `script/config/v2-mainnet.json`), runs preflight before and after the owner command, the whole deploy, postflight and a trading smoke (a sell and a buy through the universal router, a book, a real credit sold into the bid). it prints the gas of each transaction and the eth the owner needs at 1, 5 and 20 gwei. the addresses are CREATE2 addresses, so the `core` and `coin` lines the test prints after the deploy are the ones step 4 prints |
| 3 | owner command: minimum protocol skim share | the factory enforces a minimum protocol share of the baseline skim (`minProtocolSkimShareBps`, 1,000 on the v2 mainnet environment) and the launch `bountyBps` 9,638 leaves the protocol 362 of 10,000, so the factory owner (the coin owner address) lowers it to at most 362. the factory rule is `bountyBps <= min(9999, 10_000 - minProtocolSkimShareBps)`, so any value up to 362 passes, and 362 is chosen so the pool floor equals the protocol's 0.25 points: `cast send $FACTORY "setMinProtocolSkimShareBps(uint16)" 362 --rpc-url $MAINNET_RPC_URL --ledger`. send it just before the launch and wait for its receipt. confirm: `cast call $FACTORY "minProtocolSkimShareBps()(uint16)" --rpc-url $MAINNET_RPC_URL` prints 362. after step 6 has mined the launch and sent its last transaction, set it back to 1,000 in a second transaction of its own, `cast send $FACTORY "setMinProtocolSkimShareBps(uint16)" 1000 --rpc-url $MAINNET_RPC_URL --ledger`, and confirm that the call prints 1000. the setting is global to the factory and applies to every pool created after it. each pool keeps the split it was created with, so the coin of this launch keeps its 362 and the set back restores the floor of 1,000 for later launches. each of the two transactions is confirmed before the next command runs, and the owner sends nothing between the first and the last transaction of step 6 (step 4). until it is set preflight fails exactly two rows (`factory: min protocol skim share leaves room for the bounty` and `factory: deployTokenAsOwner accepts the config (simulated)`). the share row names the command: `factory minProtocolSkimShareBps is 1000, above the 362 the bounty 9638 leaves. the factory owner runs setMinProtocolSkimShareBps(362) first`. this is the only owner command the launch needs: the launch has an lp fee of 0 (the factory accepts it while the baseline skim is above 0) and no fee swapper, so nothing is registered as an escrow depositor, and no extension is used |
| 4 | preflight and the sign off | `DEPLOYER=$DEPLOYER forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL`. the output is about 1,200 lines of traces and the table is at its end: pipe it through `grep -E '^ +(WARN|FAIL|[0-9]+ of|CONFIG_HASH)'`. 117 rows on the fixture, every one must be ok (WARN rows never fail). the balance row of this step reads the chain balance. the `Deploy` dry run of step 5 reads the owner balance too high, by an amount that has grown from rehearsal to rehearsal, and passes it, so the dry run balance row is not a funding check. the latest rehearsal record lists both readings next to the chain balance. seven `build:` rows pin the build: the masked runtime code hash of the compiled Core, CoreLib, ControllerV1, CoreLens, SeaportBasicAdapter and CreditStrategyAdapter in `out/` (immutable and library address slots zeroed) and the CoreLib creation code hash each equal a constant of `script/Checks.sol`, computed from the sources at the frozen candidate. a modified tree or a stale `out/` fails them, and the system `Deploy` creates is compiled from that tree. the `signoff: build` row prints the pins. forge runs with ffi off, so the git rows are in `script/tools/check-preflight.sh` (run it from a clean checkout): the git tree is clean and HEAD contains the candidate row of the freeze table in `docs/STATUS.md`. every contract of the deploy is created at a CREATE2 address that is a function of its salt, its creation code and the config, so the predicted addresses (the signoff rows print them) do not move when the owner sends other transactions. two rows cover the coin metadata: `rule: image at most 2048 bytes, description at most 4096 bytes` fails above either cap (the factory reverts above them), and the row `rule: image and description are filled and are not placeholders` fails on chain id 1 while either is blank after trimming, holds `placeholder` in any case, is `todo` or `tbd`, or `image` carries no lowercase `ipfs://`, `https://`, `ar://` or `data:` scheme with content past it and no surrounding whitespace (a WARN row on any other chain id). three rows pin the owner account, an EIP 7702 delegation: its code is `0xef0100612373d7003d694220f7800eeaf8e3924c0951d3`, the delegate (Uniswap Calibur) has code hash `0xff0357b543bbb94845b6791a8becac5e87d467814f86538a62649c877227d631`, and `keyCount()` on the owner is 0 (no registered key can act as the owner). they hold for the moment preflight runs; the owner key can redelegate at any time. one row calls the launch payee with 0.001 eth and 100,000 gas from a funded probe address on a snapshot: a payee that reverts cannot claim its share. `script/tools/check-preflight.sh [config]` runs this command on a fork of the pin block and compares the failed rows with the expected ones. the owner balance row is compared too, so an underfunded deployer fails it. on a rehearsal fork where the balance is not the launch day balance, at the default pin block the balance row fails (the owner held 0.068 eth); run the script with `FORK_BLOCK=<latest block>` (the owner is funded) or with `IGNORE_BALANCE=1`. `IGNORE_BALANCE=1` leaves the balance row out of the comparison on both sides. the expected failed rows are then the two factory rows of step 3, and with `script/config/rehearsal.json` also the metadata row, which fails by design while a value holds `PLACEHOLDER`. the balance row reads the owner balance at the fork block and fails only while the owner holds less than the need. a reproducible run on the pin block uses `IGNORE_BALANCE=1`; the launch day run uses the latest block with the funded owner and the real `image` and `description`, and never sets `IGNORE_BALANCE`: that variable is for a rehearsal at a past block only, and without it the owner balance row is the balance gate of the launch (the `Deploy` dry run reads the owner balance too high and passes it). the config argument defaults to `script/config/mainnet.json`, the file the launch uses; the script fails on it by design while `image` or `description` is empty: on the tracked `mainnet.json` the failed rows are the metadata row plus the two factory rows, and the check passes only on a config with the real strings (the launch run uses `local.json`); it fails when the script itself stops before its table, which `forge test` cannot show because the tests call the checks through a test contract. it predicts the core, the controller, the lens, the two adapters and the coin from the salts and the creation code (the deploy creates exactly these), and it simulates `deployTokenAsOwner` on a snapshot under the 16,777,216 per transaction gas cap. read the `signoff:` rows, then `export CONFIG_HASH=0x...` with the printed `CONFIG_HASH=` value. that one value stands for the whole config. the placeholder config and the filled config give different values and every settings change moves both, so the launch hash is the one printed for the real file at this step. the latest rehearsal record lists the hashes of `rehearsal.json` and of the tracked `mainnet.json` with empty metadata at the current settings, to compare with the step 4 output of the same files; a copy of an older hash is stale. |
| 5 | dry run | `DEPLOYER=$DEPLOYER forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER`. needs `CONFIG_HASH` in the env, and refuses while `SETTINGS_CHANGED` or `COIN_CHANGED` is set. simulates all transactions, runs preflight first and postflight on the simulated result. nothing is sent. once every preflight row passes, forge prints "Estimated amount required", which excludes the factory fee sent as value, add the fee. while any preflight row fails the dry run ends with `ChecksFailed` and prints no estimate: the gas figures come from the rehearsal test (section 0). a first line `Failed to decode return value: 0x2ef9eadf...` is the same `ChecksFailed` revert; read the table and the last line. the library row reads differently in the two commands: step 4 prints that the library is not deployed and that the first transaction deploys it, the dry run prints "on chain, the broadcast skips it", because forge deploys the linked library in its own simulation before `run`. the dry run text does not mean the library is on mainnet: `cast code` of the library address is empty before step 6 (the address changes with every CoreLib change; step 4 prints the address for the candidate). expected shape (the latest rehearsal record lists the measured run, made with the placeholder config): the sender 0xCB43, an EIP 7702 delegated EOA with code, is accepted by `forge script --sender`. before `setMinProtocolSkimShareBps(362)` preflight fails the placeholder row and the two factory rows, and the dry run stops in `factory: deployTokenAsOwner accepts the config (simulated)` with `BountyBpsTooHigh(9638, 9000)`. after it only the placeholder row fails, and with the real metadata every row passes. postflight passes every row after the launch and after the lock. until the owner sets 362 the broadcast would revert `BountyBpsTooHigh(9638, 9000)` in the launch transaction after the contracts and the owner calls went out. the gas of the transactions is the table of section 0. before the broadcast, read the signer balance with `cast balance <owner> --rpc-url <rpc>` and compare it with the funding figure from step 4 (the `need` of the balance row, and the funding table of the latest rehearsal record for a higher base fee). the dry run balance row is not a funding check. the dry run sends nothing |
| 6 | broadcast | first `git checkout foundry.lock lib/solady` (the builds before this step rewrite both files, and the gate reads the tree), then `script/tools/check-freeze.sh`, run from the candidate commit: it prints one ok or fail line per row of the freeze table in `docs/STATUS.md` and exits 1 while any row is pending, a result file is missing, or the candidate row differs from `git rev-parse HEAD`. it checks the table, and the owner's authorization to broadcast stays separate. then, after the rpc test of section 0: `forge script script/Deploy.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger`. note the printed core, coin, controller and lens addresses and `export CORE=... COIN=... CONTROLLER=... LENS=...` and `export LIB=$(jq -r '.libraries[0]' broadcast/Deploy.s.sol/1/run-latest.json | cut -d: -f3)`. when the script has finished, run the set back command of step 3. if anything stops half way, do not rerun, go to section 6 |
| 7 | verify on etherscan | section 3 |
| 8 | postflight | `CORE=$CORE DEPLOYER=$DEPLOYER CONFIG_HASH=$CONFIG_HASH forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL`. record the launch price of the coin from it: the row `pool: start tick equals the config while nothing was bought` prints `tick 175000 untouched` while nobody has bought (the pool tick is the log of coin per eth, 1.0001^175000 is about 3.98e7 coin per eth). write the tick and the date into the launch record; section 4, watching the buyback after a price fall, compares every later reading with it. every row must be ok (the row count of the fixture is printed by the rehearsal test) (the row for the locked fee recipients is a WARN until `coin.lockRecipients()` is sent, section 4, the row for coin held by the Core is a WARN while the Core holds coin). it prints the constructor args of the Core and the controller (built from the config), the config hash and the rows that cannot be read from chain. the mev schedule is frozen per pool and readable at any time, so there is no window to hit |
| 9 | owner decisions, not steps | `coin.lockAllowlist()`, `coin.lockRecipients()` and `lockSuccessor()` stay open until the owner decides. section 4, the lock table |
| 12 | keeper duties | section 4 |

the launch day rule for `rateStart`. `rateStart` is the market price of one credit in wei, bounded to [1e13, 1e18] by the Core. the opening limit is the market price of a credit, and every credit costs the rate, so one credit costs `rateStart` wei at the start. the default 8.9e15 is for a market price of 0.0089 eth. set `settings.rateCap` to 3 times `rateStart` in the same edit (FLOW decisions 46 and 69): 2.67e16 for the default. preflight fails the row `rateCap is 3 times rateStart` for any other ratio, so a new `rateStart` with the old cap stops at step 4. the market price is the median of the last 24 hours of paid sales. the ceiling anchor is `rateStart` until the first fill, then the rate paid at the last fill. one line to read a recent median from the chain, from any rpc that serves logs (it samples the last 60 transactions that moved a Credit):

```sh
H=$(cast block-number --rpc-url $MAINNET_RPC_URL); cast logs --rpc-url $PRIVATE_RPC --address 0x97630aA70AB14ed9883B41dAfccBc11349723043 --from-block $((H-7200)) "Transfer(address,address,uint256)" --json | jq -r '[.[].transactionHash] | unique | .[-60:] | .[]' | while read t; do cast tx $t value --rpc-url $PRIVATE_RPC; done | grep -v '^0$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
M=10600000000000000; echo "rateStart $M rateCap $((M*3))"   # M the median in wei, rateStart is M itself, rateCap is 3 times M
```

`rateStart` is the median in wei. the shell computes `rateCap` in 64 bit integer arithmetic, exact below 9.2e18, so the cap is exactly 3 times `rateStart` for every value in the Core bounds. a floating point tool (awk `printf`, jq before 1.7) rounds integers above 2^53 (about 9.007e15) and writes a `rateCap` that is not 3 times `rateStart`, which preflight rejects. the `jq -r` reads of `.rateStart` and `.settings` in section 3 (the `RATE_START` and `SETTINGS` exports) need jq 1.7 or later: jq 1.6 rounds an integer above 2^53 to a double and the constructor arguments then differ from the config. check `jq --version` first, or read those values with a tool that keeps integers.

the value only decides how soon the pot starts working. the owner can move it after the launch with `setRate` (section 4), so a wrong guess is cheap to fix.

what the scripts do.

| script | does |
|---|---|
| `Preflight.s.sol` | read only. chain id 1, the pinned rules of section 2, code at every stack address, the v2 cross checks (the hook reports the pool manager and the escrow and lists the factory as a launcher, the locker reports the escrow and lists the factory, the mev module is bound to the hook, the hook is a core depositor and the locker a depositor of the escrow, the factory reports `STACK_VERSION` 2, the pool manager, has a token deployer, enables the hook, locker and mev module, has an empty default allowlist, and has a deploy fee of at most 0.1 eth that goes to the config owner as team fee recipient, the hook reports the pinned `constantsHash()` of the live stack and the hook, factory, locker, escrow and mev module report the same hash, nine code hash rows compare the `extcodehash` of the hook, factory, locker, escrow, mev module, token deployer, extension allowlist, protocol fee controller and burn router with the pins of the section above, and a row states the deprecated rule), the signer is the factory owner and the config owner, the factory minimum protocol skim share against the bounty, the deployer balance against fee plus gas, the predicted controller, core and coin with no code at any of them, the coin equal to the factory's own `predictToken`, code at the deterministic deployer and the library row, Credits and Statements sanity, placeholders filled, `image` and `description` inside the coin caps of 2048 and 4096 bytes (a failure on chain id 1 while either is blank after trimming, holds `placeholder`, `todo` or `tbd`, or `image` carries no scheme), `rateStart` and every `settings` field against its bound, `rateCap` equal to 3 times `rateStart`, and a simulation of `deployTokenAsOwner` with the config on a snapshot (hook flags, restriction, mev schedule, tick and fee acceptance). then the `signoff:` rows and the `CONFIG_HASH`. prints a table, reverts with the failed names |
| `Deploy.s.sol` | refuses to run while owner, creator, name, symbol or salt is unset, a value is out of bounds, `SETTINGS_CHANGED` or `COIN_CHANGED` is set, `CONFIG_HASH` is not the hash of the loaded config, or the signer is not the factory owner. runs preflight, then sends in this order: the library `CoreLib`, Core (the constructor takes the payee and computes the coin address the factory predicts for the launch), ControllerV1 (constructor argument the Core), CoreLens (read only, constructor argument the Core), `SeaportBasicAdapter` (constructor arguments the Core and the allowlist of `adapters.seaportRecipients`), `CreditStrategyAdapter`, `core.setController`, `core.addAdapter` for each adapter, `deployTokenAsOwner` with the Core as the bounty recipient. every contract of ours goes through the deterministic deployer (CREATE2) with a fixed salt. asserts the coin equals the prediction, and runs postflight on the result before anything is mined. each transaction is checked against the gas cap in the simulation |
| `Postflight.s.sol` | read only. reads the deployed system back and compares it with the config: core immutables including `COIN`, the runtime code of the Core and of the ControllerV1 against the compiled artifacts (immutables and the linked library address masked, the method of `test/BuildIdentity.t.sol`), then every masked slot: each of the eight CoreLib call sites of the Core holds the compiled library, each site of the ten Core immutables holds the value its getter returns, and each of the 28 CORE sites of the controller is the Core, settings field by field, the sale block of the controller, the credit settings of the Core and of the controller, allowed targets, the linked library, the coin (name, symbol, supply, image and description equal to the config, restricted, admin, launcher, canonical hook and pool, allowlist holding the locker, the escrow and the config entries and none of the Core, owner, creator, payee, hook, factory, mev module or controller), the pool and the mirrored launch position ticks (the coin is currency1), the hook skim config (6.9 points baseline, bounty bps, bounty recipient the Core, lp fee 0), the mev schedule, the locker slots, the Core payee state (`payee` equals the config, `payeeOn` false, `payeeOwed` 0, `payeePpm` inside its bound), the Core address as the CREATE2 address of the config and the deployer and the factory prediction when DEPLOYER is set. WARN rows for what the owner may change (no pending owner, allowlist locked, recipients not locked, supply dust). the override flags SETTINGS_CHANGED and COIN_CHANGED = 1 turn the rows for a named later change into warnings, the other rows stay strict. the state of the coin fee recipient lock is an info row |
| `Resume.s.sol` | finishes a deploy that stopped half way. section 6 |
| `Lock.s.sol` | runs the postflight, then sends `coin.lockRecipients()` as the coin admin and reads the lock back. dry run unless `SEND=1` and `--broadcast`. an owner command after the launch, section 4, the lock table |
| `SetSettings.s.sol` | owner settings changes. section 4 |

`CoreLens` is created right after the Core through the deterministic deployer (CREATE2, salt `keccak256("credits.core.lens.v1")`, the Core as constructor argument), so its address is a function of the Core and the compiled lens: `Postflight` and `Resume` derive it from `CORE` without the deployer or its nonce. `Deploy` prints it (`lens`). postflight checks the lens in every run: code of the compiled size, the pointer to the Core, the Credits and Statements constants, the controller equal to the Core's, and a `snapshot()` call that answers. `Resume` creates the lens when its address has no code, in any stage. the lens holds no funds and no permissions.

the library `CoreLib` is deployed by CREATE2 through the deterministic deployer (0x4e59b44847b379578588920ca78fbf26c0b4956c), as the first transaction of the broadcast, and skipped when it is on chain already. the Core, the controller, the lens and the two adapters are created through the same deployer with the salts `credits.core.v1`, `credits.controller.v1`, `credits.core.lens.v1`, `credits.core.seaportAdapter.v1` and `credits.core.strategyAdapter.v1` (hashed with keccak256). the Core address is a function of the compiled Core, the library, the config and the deployer; the controller address of the Core, the sale and the credit settings. a contract with code at its address is skipped, so a rerun of `Deploy` or a `Resume` continues from the chain state.

### what the scripts refuse, the config mutation matrix

`test/ReviewMatrix.t.sol` mutates the signed config and the chain state one change at a time and records which layer stops it. the 38 mutations cover every preflight row a mutation can fail with at least one case (the stack addresses, the launch fields, the rate, the people and the payee, the sale and credit bounds, the factory state, the balance, the library, the stack code) and one valid but different config for each of the pool, the coin, the controller, the Core rate and the Core settings. the result: 30 stopped by preflight, 2 reverting safely in the deploy, 1 caught by postflight, 5 changing only the config hash (a value that stays inside every bound is a different launch, not an error, the hash sign off is what stops it), 0 slips, and the unchanged config launches clean. when you change anything in the file after step 4 the hash changes and `Deploy` reverts with `ConfigHashMismatch`.

## 2. parameter sign off table

constants of the Core (compiled in, not configurable). the owner signs off each row. every economic number is a setting, see the next table.

| constant | value | meaning |
|---|---|---|
| `COIN_SUPPLY` | 1,000,000,000e18 | the launch coin supply preflight checks the token against |
| `RATE_START_MIN_WEI`, `RATE_START_MAX_WEI` | 1e13, 1e18 | bounds of the constructor argument `rateStart` and of `setRate`, wei per credit. defined once in `src/interfaces/Interfaces.sol`, shared by the Core and the scripts, no getter on the Core |
| approved adapters at deploy | `SeaportBasicAdapter`, `CreditStrategyAdapter` | `buyListing` adapters, created by the deploy (CREATE2, salts `credits.core.seaportAdapter.v1` and `credits.core.strategyAdapter.v1`) and approved by the Core constructor. the Seaport adapter allowlist at launch is `adapters.seaportRecipients` of the config (the OpenSea fee collector). the owner adds more adapters with `addAdapter` at once, until `lockAdapters()`, and manages the allowlist with `setAllowedRecipient` on the adapter |
| forbidden addresses | Credits, Statements, Core, coin, hook, pool manager, factory, locker, escrow, Permit2, position manager, universal router, balanceModule, balanceToken | checked on `addAdapter` and against the target an adapter quotes at call time. the stack members come from the config |

the skim split (6.9 points of volume in total, 9,638 bps of it to the bounty recipient, the Core) is fixed inside the artcoins pool at launch and cannot be made adjustable by this system. the Core splits what it receives by `payeePpm`, `feeToBuybackBps` and `feeToRedeemBurnBps`, which the owner changes (section 4).

settings. one struct, `Settings`, in Core storage, in the config file under `settings`, inside `CONFIG_HASH`. the owner changes any of them after the launch with `setSettings(Settings)` (all at once, effective at once, after a checkpoint of the eth rate; the whole struct is emitted in `SettingsSet`) and reads them with `settings()`. the Core rejects a value outside the bounds, and preflight rejects it first. the bounds exist to stop typos and to keep the owner from transferring assets out (caller payments and keeper rewards are capped). they do not bound the price the owner sets for credits: see the owner section of docs/SPEC.md. postflight reads every field back. the owner signs off each row. the field order is the struct order.

| key | launch | bounds | meaning | adjustable after launch |
|---|---|---|---|---|
| `dropPerCreditBps` | 50 | 1 to 1000 | each credit bought lowers the rate by this share of the rate before that credit | yes |
| `dropFloorBps` | 5000 | 5000 to 10000 | within one minute bucket the rate does not fall below this share of the price state at the first fill of the bucket | yes |
| `climbPerMinBps` | 50 | 1 to 1000 | rate climb per minute at or above the recovery level, compounded | yes |
| `ceilBps` | 11000 | 10000 to 30000 | the rate stays at or below this share of the ceiling anchor, the higher of the last fill rate and the remembered peak now (`rateStart` before the first fill) | yes |
| `idleLoosenBps` | 200 | 1 to 2000 | the ceiling anchor grows by this share of itself per full 10 minutes since the last fill | yes |
| `saleFloorBps` | 10000 | 1000 to 40000 | the hard floor of a statement sale, bps of the statement cost. `sellTo` takes no payment below it, read at the sale, and the controller lifts its quote to it. the controller prices above it (see the sale controller). at the launch value of 10000 an unsold statement sits at its reference, which is at least its cost. a low value lets a bad setting sell a statement cheap, which is why the settings are owner only and public in `SettingsSet`. a changed floor reaches every held statement at once | yes |
| `saleToBuybackBps` | 5000 | 0 to 10000 | share of sale proceeds to the coin buyback pot, the rest to the credit pot | yes |
| `recoveryClimbPerMinBps` | 200 | `climbPerMinBps` to 1000 | rate climb per minute while the price state is below the recovery level (`recoveryGapBps` under the remembered peak), compounded. at or above the level the climb is `climbPerMinBps`. lets the bid recover fast after a sale walks it well down | yes |
| `recoveryGapBps` | 1000 | 0 to 5000 | the recovery climb applies only while the price state is more than `recoveryGapBps` below the remembered peak, bps of the peak: below `peak * (10000 - recoveryGapBps) / 10000`. at or above that level the climb is `climbPerMinBps`. a sale that walks the bid less than this gap (a single credit drops 0.5 percent, a batch of 19 about 9.1 percent) climbs at the normal rate. 0 makes every fill start the recovery climb | yes |
| `peakHalfLife` | 21600 | 600 to 604800 s | seconds in which the remembered peak halves. the ceiling anchors on the higher of the last fill rate and this peak, so after a large sale the bid can climb back toward the pre sale price for about this long before the anchor settles to the last fill rate | yes |
| `buybackDelay` | 25 | 1 to 7200 blocks | minimum block gap between two coin buybacks | yes |
| `redeemOn` | false | on or off | whether `redeemStatement` runs (else `RedeemOff`). launch false, the balance side is off until the owner turns it on | yes |
| `balanceBidOn` | false | on or off | whether `sellForBalance` runs (else `BalanceBidOff`). launch false | yes |
| `redeemSlippageBps` | 200 | 0 to 1000 | a redemption must raise the Core's balance token balance by at least `rating * unitPerPoint * (10000 - redeemSlippageBps) / 10000`, where `rating` is the statement's stored rating | yes |
| `balanceBidMarginBps` | 2000 | 0 to 9000 | the balance token bid pays `score * unitPerPoint * (10000 - balanceBidMarginBps) / 10000` per credit, reading each live credit's score | yes |
| `redeemBurnBps` | 2000 | 0 to 10000 | share of `ethRedeemBurn` moved into the coin buyback on each redemption | yes |
| `buybackSlice` | 0.5 eth | 0.01 to 1 eth and at least `2 * (600,000 * keeperMaxBaseFee + keeperFee)` | coin buyback slice. the swap has no minimum output, so the slice is the size of a sandwich target: lower it after a large fall of the coin price (section 4, watching the buyback after a price fall) | yes |
| `keeperFee`, `keeperMaxBaseFee` | 0.0005 eth, 10 gwei | 0 to 0.005 eth, 1 to 100 gwei | payment to the caller of `buyback` and of `buyListing`: the gas of the call at the base fee (at most `keeperMaxBaseFee`) plus `keeperFee`. `buyback` pays from the buyback pot, counted gas at most 600,000. a buyback counts about 267,000 gas, so 0.0027 eth of gas at 10 gwei. its fee scales by the swap spent over the largest swap budget the `buybackSlice` setting allows. the swap budget is the slice less the largest possible payment, and a slice under twice that payment reverts `SliceTooSmall`. `buyListing` pays from `ethPot`, counted gas (the gas from the first line of the call, the book included, plus 250,000) at most 1,500,000, the whole `keeperFee`, and at most the bid less the listing cost, so cost plus payment never exceeds the bid. a `buyListing` counts about 450,000 to 470,000 gas, so 0.0045 to 0.0047 eth of gas at 10 gwei | yes |
| `rateCap` | 26700000000000000 | 1e13 to 1e18 (the rate bounds) | wei per credit, 3 times `rateStart` at launch. the eth rate never exceeds it: the price state is at most the lower of the ceiling and `rateCap`, `setRate` refuses a value above it, and lowering it below the live rate pulls the rate down to it at once (checkpoint first). the owner's "never pay more than this per credit". `rateStart` must not exceed it (preflight row, and the Core constructor reverts `BadRate`), and preflight requires it to be 10 times `rateStart` | yes |
| `callerFee`, `callerMaxBaseFee` | 0, 0 | 0 to 0.005 eth, 0 to 100 gwei | payment to the caller of `compose`, `composeChosen` and `redeemStatement`, from `ethPot`, at most the pot: the gas counted for the call at the base fee (at most `callerMaxBaseFee`, counted gas at most 13,700,000 for compose and composeChosen and 1,500,000 for redeemStatement) plus `callerFee`. both 0 at launch: the three doors pay exactly 0. `callerMaxBaseFee` 0 refunds no gas. turn it on with `setSettings` (changing settings after launch) | yes |
| `feeToRedeemBurnBps` | 1000 | 0 to 10000 | share of the booked pool fees, after the payee share, that fills `ethRedeemBurn`, the redeem burn reserve. the rest goes to the credit pot. each redemption moves `redeemBurnBps` of that reserve into the coin buyback | yes |
| `payeePpm` | 75185 | 0 to 200000 | parts per million of the booked pool fees owed to `payee` once the anti sniper window has passed. 75,185 ppm of the 6.65022 points the Core receives is 0.5 point of volume (0.5 / 6.65022 * 1,000,000 = 75,185.4, rounded down). the payee pulls it with `claimPayee()`. the engine keeps the rest | yes |

the credit settings are the `credit` block of the config (below), not fields of `Settings`.

one more owner function with its own event: `setRate(uint256)` resets the current eth limit (inside the rate bounds and at most `rateCap`, checkpoints first, keeps the last fill time). the balance token bid is per point, `score * unitPerPoint * (10000 - balanceBidMarginBps) / 10000` per credit, so it moves with `balanceBidMarginBps` and `balanceBidOn` through `setSettings`.

launch inputs status. filled: `owner` and `creator` (both 0xCB43078C32423F5348Cab5885911C3B5faE217F9, the factory owner), `name` and `symbol` (`CC`), `salt` (keccak256 of the string CC), the payee (the creator address). open: the launch day `rateStart`. because the owner is the creator, preflight prints the warning row `warn: owner differs from creator`; it never fails.

there is one config file, `script/config/mainnet.json`. the hash covers everything in it, so a changed launch value is a new signed hash.

config values (`script/config/mainnet.json`). the owner signs off each row.

| key | default | meaning |
|---|---|---|
| `stack.poolManager` | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap v4 pool manager |
| `stack.hook`, `factory`, `locker`, `escrow`, `mevModule` | the live stack addresses of the section "the live v2 stack" | the v2 skim hook, the v2 factory (its owner is the signer), the locker, the fee escrow and the linear skim mev module. the deploy refuses zero |
| `stack.tickSpacing`, `stack.poolFee` | 200, 8388608 (0x800000) | pool key. spacing and the dynamic fee flag |
| `owner` | 0xCB43...17F9, the factory owner | Core owner (immediate owner functions, four one way locks, two step handover), token admin, and the only signer |
| `creator` | 0xCB43...17F9 | the one project reward slot of the locker. at lp fee 0 the locker has no lp income to hand out |
| `name`, `symbol` | `CC`, `CC` | coin name and symbol. deploy refuses an empty name |
| `salt` | keccak256 of the string CC (0x56d96069...258a9c) | user salt of the coin address. any nonzero value, change it if the predicted address is taken |
| `rateStart` | 8.9e15 | opening bid in wei per credit, bounded to [1e13, 1e18] and to `settings.rateCap`. launch day rule in section 1 |
| `settings` | the table above | the launch value of every economic setting, in the hash |
| `sale` | `15000, 100000, 100, 10000, 25, 604800, 100000000000000000` | the controller sale settings, constructor arguments of `ControllerV1`: `markupBps` (start price over the anchor), `startCapBps` (most the start price can be, bps of the price reference), `fastDecayBpsPerHour` (fall of the asking price per hour above the knee, bps of the reference), `kneeBps` (price where the fast fall ends, 1000 to `startCapBps`), `slowDecayBpsPerHour` (fall per hour below the knee), `anchorHalfLife` (seconds for the part of the anchor above 10000 to halve, 1 day to 90 days), `anchorMinCost` (wei, the least statement cost whose buy moves the anchor, 0 to 10 ether, 0.1 ether at launch). the anchor starts at 10000 and is not a constructor argument. the asking price falls to the Core setting `saleFloorBps` of the reference |
| `credit` | `10000, false, 1000000000000000000, false, 14400, 11000, 30000, 4330000, 250, <artist address>` | the credit settings, constructor arguments of the Core (the first three) and of `ControllerV1` (the last seven), in the hash. `costToPotBps` (0 to 10000, share of a sold credit's cost booked to `ethPot`, the rest of the payment to the coin buyback pot), `chosenComposeOn` (whether `composeChosen` is open), `minCcToChoose` (least coin balance of the caller of `composeChosen` and `setHeldFormat`, uint96 base units, 1 coin at launch), `saleOn` (the credit sale window), `window` (seconds, 60 to 2592000, a credit's price fall time and the time it waits before compose), `floorBps` (10000 to 40000, bps over the larger of the credit's cost and `valueOf(score)`), `startBps` (10000 to 200000, bps over the floor), `refScore` (1 to 8000000, the per-credit score unit of the statement price reference, ten-thousandths of a point), `royaltyBps` (0 to 1000, the share of every sale price added on top, 250 at launch) and `royaltyRecipient` (the artist address, never zero; the shipped file carries the creator address until the owner names the artist, and preflight prints a sign off row `signoff: royalty`). preflight checks the bounds of `CreditBounds` and prints the sign off rows `signoff: credit sale` and `signoff: chosen composition`; postflight reads every value back from both contracts. the owner changes each afterwards with its own setter (docs/SPEC.md section 10) |
| `launch.supply` | 1,000,000,000e18 | coin supply, all of it in the launch position. must equal the Core `SUPPLY`. the locker burns about 3,551 wei of dust to the dead address at the launch, so the live supply is a hair under it |
| `launch.startTick` | -175000 | `tickIfToken0IsCoin`, about 40M coin per eth. a multiple of the spacing and equal to `positionLower` |
| `launch.positionLower`, `positionUpper` | -175000, 887200 | the one launch position, configured as if the coin were token0. the coin is currency1 of the pool, so the ticks on chain are mirrored (-887200 and 175000), postflight checks the mirrored values |
| `launch.baselineSkimBps` | 690 | baseline skim in basis points of volume: 6.9 points. a trader pays 6.9 percent in total |
| `launch.bountyBps` | 9638 | share of the baseline skim that goes to the bounty recipient, the Core: 6.9 * 9,638 / 10,000 = 6.65022 points of volume. the protocol keeps 362 of 10,000 of the skim: 6.9 * 362 / 10,000 = 0.24978 points of volume (about 0.25). the sniper extra goes whole to the bounty recipient |
| `launch.maxReferralBps`, `launch.lpFeePips` | 0, 0 | referral cap (bps of volume) and lp fee (uniswap pips), both pinned to 0 |
| `launch.sniperStartBps`, `launch.sniperSeconds` | 9000, 1800 | the mev module skim decays linearly from 90 points to the baseline over 30 minutes |
| `launch.protocolBps` | 2000 | the `protocolBps` argument of `deployTokenAsOwner`, pinned to 2000. the protocol leg belongs to the launcher protocol, a separate business from this engine: it is never the engine owner's income. preflight warns when the factory default differs |
| `launch.restricted`, `launch.allowed` | true, empty | the coin launches restricted. the allowlist holds the entries the factory seeds (the locker and the escrow, pinned). the Core is not listed (decision 29): the buyback take passes the restriction through the transfer allowance the hook grants for the swap. no config entries, the factory default allowlist must be empty. the coin address is the factory's prediction for the signer, the Core address and the config, so it is known once the Core address is known |
| `payee.address` | 0xCB43...17F9 | the payee of the Core at launch (the creator address): `claimPayee()` pays it the share `payeePpm` of the settings table accrues. the owner repoints it later with `setPayee(address)` |
| `overrides.bounty`, `overrides.openFactory` | false, false | `bounty` allows any bounty bps below 10000, `openFactory` allows a non deprecated factory. both inside the hash |

pinned rules. preflight fails (and `Deploy` stops) on any value outside them. each row is a check in `script/Checks.sol`.

| rule | pinned to | override |
|---|---|---|
| tick spacing, pool fee | 1 to 32767, the dynamic fee flag 0x800000 | none |
| `startTick`, `positionLower`, `positionUpper` | multiples of the spacing, `positionLower` equals `startTick`, `positionUpper` the highest usable multiple, lower below upper | none |
| `baselineSkimBps` | exactly 690 | none |
| `bountyBps` | exactly 9638 | `overrides.bounty` |
| `maxReferralBps`, `lpFeePips` | 0 and 0 | none |
| `sniperStartBps`, `sniperSeconds` | 5000 to 9000 and above the baseline, 600 to 3600 | none |
| `protocolBps` | 2000 | none |
| restriction | restricted, no config allowlist entries, the factory default allowlist empty | none |
| factory deploy fee | at most 0.1 eth | none |
| factory | deprecated, so only the owner can launch | `overrides.openFactory` |
| factory minimum protocol skim share | at most 10,000 less the config `bountyBps` (362 after the owner command) | none |
| `payee` | nonzero, `payeePpm` at most 200,000 ppm (inside `settings`) | none |
| `owner`, `creator`, `payee` | not the dead address, a stack address or the mev module. WARN when owner and creator differ | none |
| `supply`, `rateStart`, `settings` | the Core `SUPPLY`, the rate bounds and `rateCap`, every field inside its bound | none |

a change of a pinned value means editing `script/Checks.sol` on purpose, in a reviewed commit. a pinned rule cannot know a value that is plausible but not the intended one (another start price, `owner` and `creator` swapped). those are covered by the sign off: preflight prints the `signoff:` rows, the owner signs them, and `CONFIG_HASH` is the one value `Deploy` needs in its env. the overrides are inside the hash too.

what the sign off table covers: owner, creator, the signer, the predicted controller and core addresses, the opening bid, one row per setting, the payee, and the economics line (skim, bounty, sniper).

### mainnet gas cap per transaction

mainnet caps one transaction at 16,777,216 gas (EIP-7825). every transaction of this system fits, and preflight simulates the launch under that cap (a create2 collision burns every forwarded gas, so the simulation forwards exactly the cap). the ten deploy transactions are measured by the rehearsal (execution plus code deposit, intrinsic and calldata), and the latest rehearsal record lists the gas of each and their sum. the core is the largest (5.17 million) and the sum stays under `DEPLOY_GAS_ESTIMATE`. the largest after the deploy, measured by `test/GasCap.t.sol` on the pinned fork:

| transaction | gas | share of the cap |
|---|---|---|
| `compose()`, 80 credits, first compose | 8,491,518 after the refund, 10.60 million before it | 50.6 percent after the refund, 63.2 percent before it  |
| every other call (doors, buybacks, `book`, owner calls) | under 500,000 | under 3 percent |
| `buyListing`, CreditStrategy adapter path, with 1 eth of unbooked income | 454,789 | 2.7 percent |

`compose` sits at about half the cap because the live Statements contract needs 7.90 to 8.07 million gas for 80 credits across pages of real credits, and the measured `compose` is 8.48 million, after the EIP-3529 refund of the cleared credit records (2.12 million). the gas before the refund is 10.60 million, and a transaction needs a gas limit above the gas before the refund. a keeper must not hardcode a gas limit under 12 million for it. `composeChosen` runs the same internal path and its gas row is pending. `sellForEth` and `sellForBalance` take any number of credits: the cap stops a batch at about 115 credits (eth bid) or 125 (balance bid); the eth figures include a book of pending income, and a larger call simply reverts for its sender. the gas capped reads inside the Core use under half of their caps. `balanceModule` is a stand in in these tests: what a real one spends inside `redeem` is added to `redeemStatement`, and the Core forwards it all the remaining gas.

## 3. verify on etherscan

the compiler settings are in `foundry.toml`: solc 0.8.30, evm cancun, via ir, optimizer 200 runs, `bytecode_hash = "none"`. the contracts we own are the library `CoreLib` (`src/lib/CoreLib.sol`), ControllerV1, Core, CoreLens and the two listing adapters. the coin, hook, factory, locker and escrow are artcoins contracts and verify on their own.

the library address is the CREATE2 address of the compiled code: take it from `jq -r '.libraries[0]' broadcast/Deploy.s.sol/1/run-latest.json | cut -d: -f3` or from the line `verify: library CoreLib at` that postflight prints. export it as `LIB`. the Core links against it, so verifying the Core needs `--libraries src/lib/CoreLib.sol:CoreLib:$LIB`. verify the library first, it has no constructor arguments. postflight prints the exact `--libraries` flag and the constructor args of the Core and the controller (`verify:` lines), built from the config and the first controller, never from live storage.

the constructor arguments of the Core are `(owner, cfg, launcher, coin, payee, stack, rateStart, settings, credit)`: `cfg` is the v2 factory deployment config built with the bounty recipient set to the zero address, `launcher` is the deploy signer and `coin` is the zero address at a launch. postflight prints the encoded arguments as `verify: core constructor args`. take them from there:

```sh
export ARGS=0x...   # the printed verify: core constructor args
```

forge verify-contract $LIB src/lib/CoreLib.sol:CoreLib --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir

forge verify-contract $CORE src/Core.sol:Core --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --libraries src/lib/CoreLib.sol:CoreLib:$LIB \
  --constructor-args $ARGS

forge verify-contract $LENS src/CoreLens.sol:CoreLens --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $(cast abi-encode "constructor(address)" $CORE)

forge verify-contract $CONTROLLER src/ControllerV1.sol:ControllerV1 --chain 1 --watch \
  --compiler-version 0.8.30 --evm-version cancun --num-of-optimizations 200 --via-ir \
  --constructor-args $(cast abi-encode "constructor(address,(uint16,uint32,uint16,uint32,uint16,uint32,uint128),(uint16,bool,uint96,bool,uint32,uint16,uint32,uint32,uint16,address))" $CORE "($(jq -r '.sale | [.markupBps,.startCapBps,.fastDecayBpsPerHour,.kneeBps,.slowDecayBpsPerHour,.anchorHalfLife,.anchorMinCost] | map(tostring) | join(",")' $LAUNCH_CONFIG))" "$CREDIT")
```

`forge verify-contract` needs `ETHERSCAN_API_KEY`. `CONTROLLER` is the address `Deploy` printed (a CREATE2 address), not what `controller()` answers now.

verify without the network, to prove that the files you submit are the ones that were broadcast:

```sh
INPUT=$(jq -r '[.transactions[] | select(.contractName=="Core")][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
CODE=$(forge inspect src/Core.sol:Core bytecode --libraries src/lib/CoreLib.sol:CoreLib:$LIB)
SALT=$(cast keccak "credits.core.v1")   # the deterministic deployer takes the salt first
[ "${SALT}${CODE#0x}${ARGS#0x}" = "$INPUT" ] && echo creation input equal
```

if etherscan rejects `--libraries`, use the standard json route: `forge verify-contract $CORE src/Core.sol:Core --libraries src/lib/CoreLib.sol:CoreLib:$LIB --show-standard-json-input > core.json` and upload it on the etherscan page "Solidity (Standard-Json-Input)" with compiler 0.8.30, optimizer 200 runs and the constructor args hex without the `0x`.

## 4. after launch

all times are from the launch block. the anti sniper window is `launch.sniperSeconds` long (1800 seconds), measured from pool creation, which is the launch transaction. the Core owes the payee from the first book at or after the launch time recorded by the factory plus the window: that book shares nothing and sets `payeeOn`, so eth that arrived during the window is never shared.

### the Core as fee recipient, owner commands

the Core is the bounty recipient of the pool: the v2 hook pushes the bounty to it with a 2,300 gas stipend, and `receive()` accepts only the hook and the fee escrow. every eth pot door (`sellForEth`, `buyListing`, `compose`, `composeChosen`, `adopt`, `redeemStatement`, `buyback`, `sellTo`, `sellCreditTo`) books the eth above the tracked pots first, so no keeper is needed. read first:

```sh
cast call $CORE "payee()(address)" --rpc-url $MAINNET_RPC_URL
cast call $CORE "payeeOn()(bool)" --rpc-url $MAINNET_RPC_URL; cast call $CORE "payeeOwed()(uint256)" --rpc-url $MAINNET_RPC_URL
```

| command | effect |
|---|---|
| `cast send $CORE "setPayee(address)" $NEW_PAYEE` | the owner points the payee share at another address at once, never zero. it applies to the eth already owed. a payee contract is called with all remaining gas by `claimPayee()`; a payee that reverts blocks only its own claim |
| `cast send $CORE "setSettings(...)"` | `payeePpm` is a field of `Settings` (at most 200,000), changed with the other settings |
| `cast send $CORE "claimPayee()"` | anyone. sends `payeeOwed` to `payee` |
| `cast send $CORE "fund()" --value $WEI` | anyone. adds eth to the pot whole, after booking the pending income |
| `cast send $HOOK "setBountyRecipient(bytes32,address)" $POOL_ID $NEW_CORE` | the coin admin (the owner) points the hook bounty leg at another contract until `coin.lockRecipients()`. this is the migration switch for a successor Core. a stolen owner key can redirect the fee stream with it until the lock |

### the lock table

all four locks are owner decisions and one way. the other Core locks are in the section "owner doors, locks and the handover". `cast` lines run as the signer named in the row.

| lock | kind | command | what it freezes |
|---|---|---|---|
| `coin.lockRecipients()` | owner decision | `cast send $COIN "lockRecipients()" --rpc-url $MAINNET_RPC_URL --ledger` (the coin admin, the owner), or `CORE=$CORE SEND=1 forge script script/Lock.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --ledger`, which runs the postflight first, stops on a failed row and requires the hook bounty recipient to be the Core. confirm with the postflight row `coin: fee recipients` | the hook bounty recipient (the Core) and the locker reward recipients. it ends `setBountyRecipient`, so a successor Core cannot take over the fee stream afterwards. call it together with `lockSuccessor()`, when no migration is wanted any more |
| `coin.lockAllowlist()` | owner decision | `cast send $COIN "lockAllowlist()" --rpc-url $MAINNET_RPC_URL --ledger` (the coin admin, the owner) | `setAllowed` and `unrestrict`: the allowlist and the restriction. postflight warns once it is taken |
| `core.lockSuccessor()` | owner decision | `cast send $CORE "lockSuccessor()" --rpc-url $MAINNET_RPC_URL --ledger` (the Core owner) | `setSuccessor`. with the successor still zero it disables `migrate`. before the old engine has sold out its statements it leaves the pots and credits that arrive later unmovable, because `migrate` can no longer be repointed. lock only a successor that was dry run, after the old engine has sold out |

### moving to a successor engine

the order, as the Core owner and the coin admin (one key at launch):

1. deploy and verify the successor Core (sections 1 and 3). it needs a `fund()` that takes eth and accepts the balance token and Credits by `transfer` and `transferFrom`.
2. `cast send $HOOK "setBountyRecipient(bytes32,address)" $POOL_ID $SUCCESSOR` as the coin admin. the successor is built with the live coin (`coin_` of its constructor). from the next swap the pool pays the successor. the old Core keeps the fee eth already pushed to it and books it at its next door. this step needs `coin.lockRecipients()` not sent.
3. `cast send $CORE "setSuccessor(address)" $SUCCESSOR`, then a dry run of `migrate` (the paragraph on the successor in "owner doors, locks and the handover").
4. `cast send $CORE "migrate(uint256)" $BATCH` in batches until `ethPot`, `balancePot` and the pile are 0. the first call retires the old Core. `ethToBuyback` and `ethRedeemBurn` stay in it: `buyback()` keeps burning coin there (FLOW decision 86), and the successor books the balance token it receives into its own `balancePot`.
5. the migrated eth reaches the successor through `fund()` and lands in its pot. the migrated balance token is booked by `cast send $SUCCESSOR "bookBalance()"` once the successor's balance module is set (`setBalanceModule`), so set the balance module first.
6. on the successor, `adopt(ids)` for the credits that arrived without records.
7. while the old Core holds statements, `migrate` again after each sale: it moves the booked pot share, which the successor takes through `fund()`.
8. a balance token whose `transfer` fails (reverts, returns false) leaves `balancePot` in the old Core: `migrate` still moves the eth and the credits, retires the Core and logs `BalanceTokenMigrationSkipped(successor, amount)`. repeat `migrate` once the token transfers again.

`coin.lockRecipients()` before step 2 fixes the old Core as the fee recipient, and the retired Core books every later fee. `lockSuccessor()` with the successor still zero, or before the old engine has sold out, leaves the pots and credits that arrive later unmovable.

### keeper duties

anyone can run these. none is needed for safety, they keep the engine moving. no booking keeper is needed: every eth pot door books the pending fees first.

| duty | call | note |
|---|---|---|
| book the fee eth (optional) | `core.book()` | books the eth above the tracked pots: the payee share to `payeeOwed`, the buyback and redeem reserve shares, the rest to `ethPot`. an empty balance is a no op |
| collect the creator slot | `locker.collectRewards(coin)` | pushes the recipient shares. the locker `keeperRewardBps` is 0, so the caller is paid nothing. at lp fee 0 there is no lp income, so this moves only dust |
| collect the escrow credit | `core.collectEscrow()` | claims the eth the fee escrow owes the Core (a partial fill refund of its own buyback) into the pot. reverts with the escrow's error when nothing is owed |
| compose statements | `core.compose()` (and `core.composeChosen(ids, format)` when the owner opens it) | 8.48 million measured for 80 credits after the refund, 10.60 million before it, including the book. the caller is paid from `ethPot` once the owner sets `callerFee` or `callerMaxBaseFee` (0 at launch, section 4 changing settings after launch). holders compose, and the owner composes when nobody does. set the gas limit above 12 million (the cap is 16,777,216) |
| adopt credits | `core.adopt(ids)` | puts credits that were transferred to the Core outside its doors into the pile at the basis of the price state now. event `CreditAdopted` |
| buy credits from the pile | `controller.buyCredit(id)`, `controller.buyCredits(ids)` | while the owner has the credit sale window on (`creditSaleOn`, off at launch). each credit sells at `creditPrice(id)`, falling from the start to the floor over `creditWindow`. the payment must cover the price, the excess is refunded. proceeds: `creditCostToPotBps` of the credit's cost to `ethPot`, the rest to the coin buyback pot |
| fill listings below the bid (owner keeper, backup) | `core.buyListing(adapter, id, params)` | outside bots are the primary callers: the payment is the gas of the call at the base fee (at most `keeperMaxBaseFee`, 10 gwei) plus `keeperFee` (0.0005 eth), at most the gap between the bid and the listing price (the adapter refuses a payout to the caller, so the engine keeps the gap). a caller profits when the payment exceeds its own gas cost: at 2 gwei and no priority fee a basic Seaport order costs about 0.00086 eth, which a gap of 10 percent under the opening bid of 0.0089 eth just covers, and a gap above 0.0014 eth pays about 0.00054 eth over cost. the owner keeper is a separate project that ships before launch and acts only when a listing has sat below the bid for 3 minutes with nobody filling it. it simulates before it sends and sends through a private relay (Flashbots Protect or MEV Blocker), so a lost race costs no gas (FLOW decisions 69 and 74) |
| buyback | `core.buyback()` | burns coin bought with one slice of the buyback pot, caller paid the gas of the call plus `keeperFee` |
| claim the payee share | `core.claimPayee()` | sends `payeeOwed` to `payee`. a payee that reverts blocks only this call |

| when | what happens | what to do |
|---|---|---|
| launch block | the pool is live. the skim is 90 points of volume; the bounty share of the baseline and the whole extra go to the Core, which books them at its next door (or at `book()`), and owes the payee none of the window. the price state sits at `rateStart` (`rateAtCheckpoint()`) and `ethRate()` reads the clamp of the pot, zero while the pot is empty | read postflight. nothing else is needed |
| first buy | the bounty eth lands in the Core. the next door books it into `ethPot` (`FeesAdded` fires) | call `book()` or any eth pot door, then check `ethPot` plus the other tracked pots and the Core balance are equal |
| price paid | the price state climbs lazily, `climbPerMinBps` a minute (50), compounded, up to the lower of `rateCap` and `ceilBps` (110 percent) of the price state at the last fill, loosened by `idleLoosenBps` (2 percent) per 10 idle minutes, and not past the clamp. the price paid is the read: the price state lowered to the clamp, the pot (the price of one credit that the pot affords). the read equals the price state once the pot reaches the price state: at `rateStart` 8.9e15 that is 8.9e15 wei, at 1e13 it is 1e13, at 1e18 it is 1e18. a price state above the clamp holds, so a small pot adds no climb. unsold statements do not stop the buying | watch `ethRate()` and `rateAtCheckpoint()` |
| 30 minutes | the anti sniper window ends and the skim is the 6.9 point baseline. the public can add liquidity to the pool after it | none |
| any time after the pot is funded | credit holders can call `sellForEth` into the bid. every credit is paid the read, the rate now, whatever the credit, up to the pot. fee eth that arrives raises the pot as it arrives | check that real credits clear |
| the clamp | what the engine pays never exceeds the pot, so a credit always fits. the clamp lowers the price paid and leaves the price state: with a small pot the engine pays less, the price state keeps its value, and a larger pot puts the read back at the price state. a batch whose running total reaches the pot leaves a price of zero for the next credit, which reverts `ZeroAmount`, and the revert undoes the whole call, so the batch pays nothing | none |
| with no fills | the bid climbs 0.5 percent a minute (2 percent a minute while below the remembered peak) up to 110 percent of the ceiling anchor, the higher of the last fill rate and the peak now, and that ceiling grows 2 percent of the anchor per 10 idle minutes, so a bid that nobody hits follows the market up after a gap (a market that doubles is reached in about 7 hours; FLOW decisions 69 and 74). outside bots call `buyListing` to take the listings below the bid in the meantime | none |
| statements | each compose leaves the statement in the Core. the controller prices a statement in percent of its price reference (its cost for a statement at or below the reference rating): 150 percent at compose (1.5 times the anchor, which starts at 100 percent), falling 1 percent of the reference an hour to 100 percent at hour 50, where it stays (the launch `kneeBps` and the Core setting `saleFloorBps` are both 10000). `ControllerV1.buy(sid)` pays the asking price and gets the statement at once through `Core.sellTo`, and a sale above the anchor moves the anchor halfway to the sale price, and the anchor halves its excess over 10000 every 7 days. the hard floor `saleFloorBps` (10000) binds the sale, so an unsold statement sits at its reference, which is at least its cost. the payment is booked at once, split by `saleToBuybackBps` | check `priceOf(sid)` and `statementInfo(sid)` after the first compose, then that the first sale clears and the pots rise by the payment |
| eth in `ethToBuyback` | it fills from statement sales (`sellTo`), from credit sales and from the redeem burn reserve (`releaseRedeemBurn`, and each redemption), so with the launch settings only after the first sale. `buyback()` then burns coin, one slice of 0.5 eth at launch (bound 1 eth) every 25 blocks | anyone may call, the caller is paid the gas of the call plus `keeperFee` from the slice |
| settings | the owner may change any setting at once with `setSettings(Settings)` and the eth limit with `setRate`. the owner (a plain address with immediate functions, no timelock) cannot transfer eth, credits, statements or balance token out of the Core by any setting (the owner directed transfers are `rescueCoin`, `rescueNft` and `migrate`, which sends eth, credits and balance token to the successor the owner set until `lockSuccessor()`): caller payments and keeper rewards are capped and everything else is spent only by the engine's own doors. the owner does set the price the engine pays, so a dishonest owner or a stolen owner key could sell credits to the engine at an inflated limit and drain the pot as far as the pot reaches, docs/SPEC.md section 10 (the owner accepted this, holders trust the owner key). use a multisig as owner | after any change read `settings()` and the `SettingsSet` event |
| the balance side | the balance side is off at launch (`redeemOn` and `balanceBidOn` false). the owner sets the two switches and the module with `setBalanceModule(address)`, each at once, and may replace the module until `lockBalanceModule()`: a new module must report the same `balanceToken()`, and `unitPerPoint` is validated at every set and read from the module at every use. redeemed balance token goes to `balancePot`; the balance token bid (`balanceBidOn`) pays per credit score | set it only after the module is final. a later replacement is possible and takes effect in the same transaction, so lock it only once the module is final; a rate change of the module applies to the next redemption, bid and price at once |

housekeeping after launch.

| item | action |
|---|---|
| owner commands on v2 | the one before the launch is `setMinProtocolSkimShareBps(362)` (step 3 of section 1). the launch registers the coin with the factory, the Core as the hook bounty recipient, the locker reward slots (creator 8,000 bps, protocol 2,000 bps) and the mev schedule of the coin |
| coin rescue | `core.rescueCoin(to, amount)`, owner only, for coin that an allowlisted holder sent to the Core (the Core is off the coin allowlist, so a holder that is not listed cannot send it coin). it moves coin only, never eth, credits, statements or balanceToken. the Core is off the allowlist, so `to` must be a listed address (the sender is, or the coin admin lists it first with `setAllowed`). postflight warns while the Core holds coin |
| token admin | the owner holds it. on the restricted coin it can `setAllowed(account, bool)` (not the pool manager or the canonical hook, and the factory seeded entries cannot be removed), `unrestrict()` (one way, turns the restriction off from then on, which opens side pools and lets volume bypass the skim, so it is a decision about fee income), `lockAllowlist()` (the allowlist and the restriction are frozen), set the image and description, `updateAdmin` and `renounceAdmin`. it also repoints the hook bounty recipient (`setBountyRecipient(poolId, recipient)` on the hook, which is the Core at launch) and the locker reward recipients (`setRewardRecipient(coin, index, recipient)`, the protocol slot excluded) until it calls `lockRecipients()`, which freezes both. renouncing the admin freezes the recipients too. postflight warns once the allowlist is locked and prints the lock state of the recipients. after a change run postflight with `COIN_CHANGED=1` |
| owner handover | `transferOwnership(multisig)` on the Core, then `acceptOwnership()` from the multisig, afterwards run postflight against a local copy of the config that names the new owner (and with `COIN_CHANGED=1` for the coin admin). postflight warns while a `pendingOwner()` is set |
| credits and statements | the Core receives credits and statements through its own doors only. there is no door that moves a credit or a statement out except the engine's own sales and redemptions |
| the launch key | the factory owner key is also the deployer, there is nothing to revoke. sweep nothing from it, it is the owner |

### the coin's metadata after launch

the coin admin (the owner) holds the coin's metadata. `image` and `description` are set at launch from the config (section 1, step 1). a metadata renderer is deployed after launch and set by the coin admin. every command below is sent by the coin admin.

| action | command |
|---|---|
| read | `cast call $COIN "imageUrl()(string)"`, `"description()(string)"` and `"metadataRenderer()(address)"` |
| change the image | `cast send $COIN "updateImage(string)" "$URL" --rpc-url $MAINNET_RPC_URL --ledger`. at most 2048 bytes. logs `UpdateImage` and `ContractURIUpdated` |
| change the description | `cast send $COIN "updateDescription(string)" "$TEXT" --rpc-url $MAINNET_RPC_URL --ledger`. at most 4096 bytes. logs `UpdateDescription` and `ContractURIUpdated` |
| set the renderer | deploy the renderer contract first (the coin refuses an address without code, `InvalidRenderer`), then `cast send $COIN "setMetadataRenderer(address)" $RENDERER --rpc-url $MAINNET_RPC_URL --ledger`. the zero address selects the built in json. logs `MetadataRendererUpdated` |
| freeze | `renounceAdmin()` freezes the image, the description and the renderer together with every other admin power of the coin |

after any of these, run postflight with `COIN_CHANGED=1`: the rows `coin: image equals the config`, `coin: description equals the config` and `coin: no metadata renderer` then print as warnings.

### changing settings after launch

every setting of the table in section 2 is adjustable by the owner after launch, all at once, effective at once. the Core rejects a struct outside the bounds (`SettingsBounds`) and the cross field rule (`feeToRedeemBurnBps` at most 10_000). the owner signs with `--ledger` or `--account <name>`. `setSettings` takes the whole struct, so always read the live one first, change one field, send it all back. after a change postflight fails the row `core: settings equal the config` until you run it with `SETTINGS_CHANGED=1` (it turns a warning, the other rows stay strict). the same flag lets `Resume` run on a Core whose settings changed.

the owner account is EIP 7702 delegated and a node accepts one in flight transaction from it: every `SetSettings` send and every other command that sends more than one transaction from the owner account takes `--slow` (forge waits for each receipt), and a sequence of `cast send` waits for each receipt before the next. without it `setSettings` can land while the `setRate` after it is rejected.

the script way (reads the live struct, prints a before and after table with the bounds, a `WARNING` row when the new `rateCap` is below the live bid (`ethRate`) or price state (`ethPrice`), the calldata and the `cast send` line, sends only with `SEND=1` and `--broadcast` and when the signer is the Core owner):

```sh
export CORE=0x...                       # the live Core
SET_saleFloorBps=8000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL           # dry run, sends nothing
SETTINGS_PATCH='{"saleFloorBps":8000,"redeemOn":1}' forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL   # a json patch, text or file path
SET_saleFloorBps=8000 SET_RATE=20000000000000 SEND=1 forge script script/SetSettings.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger   # sends setSettings and setRate
```

a change of `saleFloorBps` or of a controller setting reaches every held statement at once: the Core reads the floor at the sale and the controller prices from its settings at each call, so no follow up call is needed.

`SET_<field>` and `SETTINGS_PATCH` name the fields of the table, the single variables win over the patch, `SET_RATE` adds `setRate`. checked on the anvil fork: the table showed the live value 9000 and the new one 8000, the broadcast from the impersonated owner changed `saleFloorBps` and the rate.

the by hand way, with `cast`. the tuple type is the one of the constructor in section 3 (`T` below). the struct has 23 fields in the order of `Settings` in `src/interfaces/Interfaces.sol`: field 6 is `saleFloorBps`, field 12 is `redeemOn`, field 13 is `balanceBidOn`, field 17 is `buybackSlice`, field 20 is `rateCap` and field 23 is `feeToRedeemBurnBps`. the two switches print as `true` or `false` and `cast` takes the same words back. the `echo` line prints the field name with its value before and after the change: read it, and send only when the name and both values are the ones intended (a wrong index changes another setting, and the Core accepts any value inside its bounds):

```sh
T="(uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,bool,bool,uint16,uint16,uint16,uint128,uint64,uint48,uint64,uint64,uint48,uint16)"
S=$(cast call $CORE "settings()($T)" --rpc-url $MAINNET_RPC_URL | sed -E 's/ \[[^]]*\]//g')   # the live struct, plain numbers
NEW=$(echo "$S" | tr -d '() ' | awk -F, -v OFS=, '{$6=8000; print "(" $0 ")"}')                 # change field 6 (saleFloorBps) only
echo "$S"; echo "$NEW"                                                                          # read both before sending
echo "saleFloorBps before $(echo "$S" | tr -d '() ' | cut -d, -f6) after $(echo "$NEW" | tr -d '() ' | cut -d, -f6)"   # the name and the two values
cast send $CORE "setSettings($T)" "$NEW" --rpc-url $PRIVATE_RPC --ledger                        # as the owner
cast send $CORE "setRate(uint256)" 9000000000000000 --rpc-url $PRIVATE_RPC --ledger               # the eth limit, wei per credit, 1e13 to 1e18
cast call $CORE "settings()($T)" --rpc-url $MAINNET_RPC_URL; cast call $CORE "ethRate()(uint256)" --rpc-url $MAINNET_RPC_URL
```

`setRate` checkpoints the rate first, keeps the last fill time and resets the limit to the new value. read back with `settings()` and `ethRate()`, and the `SettingsSet` event. both flows were run on the anvil fork as the impersonated owner.

turning on the caller payment of `compose`, `composeChosen` and `redeemStatement` is `setSettings` with `callerFee` and `callerMaxBaseFee` (both 0 at launch, and 0 in `callerMaxBaseFee` refunds no gas). for example 0.0005 eth and 10 gwei: `SET_callerFee=500000000000000 SET_callerMaxBaseFee=10000000000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL` for the dry run, then the same with `SEND=1` and `--broadcast --slow --ledger`. the payment comes out of `ethPot`, so it lowers the eth rate by the pot it takes. a compose pays at most 13,700,000 gas at `callerMaxBaseFee` plus `callerFee`, a redemption at most 1,500,000 gas at it plus `callerFee`. at the setting bounds (`callerMaxBaseFee` 100 gwei, `callerFee` 0.005 eth) the largest compose payment is 13,700,000 * 100 gwei + 0.005 eth = 1.375 eth, above the launch page cost of about 0.71 eth: read the two values back before sending. to turn it off set both back to 0. the counted gas is the gross the transaction uses, which includes the roughly 2.12M of gas the EVM refunds at the end for storage clears, so when the payment is on compose pays for that refunded gas too; both caller settings are 0 at launch.

### a dump that walks the bid down, and statements above the floor

each minute a seller can walk the bid down to 50 percent of the minute's first price (`dropFloorBps` 5_000). the ceiling anchors on the higher of the last fill rate and the remembered peak, which halves every `peakHalfLife` (6 hours), so after a dump the ceiling stays near the pre dump price and the bid climbs back at `recoveryClimbPerMinBps` (2 percent a minute) while below the recovery level (`recoveryGapBps` 1_000, so 10 percent under the peak). measured at the launch settings: a one minute dump of 140 credits halves the bid and it is back at the pre dump price in 59 minutes (fast from the floor up to the recovery level, then the slow climb over the last 10 percent to the peak); a three minute dump of 420 credits (down to about an eighth) recovers in 146 minutes (2.4 hours). a sale that walks the bid less than the gap climbs at the normal `climbPerMinBps` rate: over one hour at the opening price a lone seller of one credit at a time sells 60 credits, batches of 10 sell 60 and batches of 19 sell 76. after a real market fall where sellers keep filling, the peak decays and the bid follows the market down; the bid sits at most about 6 percent over the latest fill price within the keeper's 3 minute window. between fills the bid can fall as the remembered peak decays (at most about 0.19 percent a minute at the launch half life), so the read is not monotone across quiet periods. the owner can still restore the bid at once with `setRate` to the market price (the `SET_RATE` line of the settings script, or `cast send $CORE "setRate(uint256)" <wei per credit>`), which also restates the peak. read `ethRate()`, `ethPrice()` and the last `EthRateFill` events to see a dump.

statements whose credits cost more than the market price sit above market at the launch hard floor (`saleFloorBps` 10000, 100 percent of cost, decision 85), so they stay unsold until the market reaches their cost or the balance side is on. if statements sit unsold, the owner lowers `saleFloorBps` (bound 1000) with `setSettings`. a held statement follows it at once.

### watching the buyback after a price fall

`buyback()` swaps `buybackSlice` eth for coin with no minimum output. the eth a sandwich around that swap can take scales with the slice and falls with pool depth: measured on a fork (docs/reviews/REVIEW-sandwich-delegate.md), a 0.5 eth slice stays unprofitable to sandwich down to about a quarter of the launch depth, and below that a bot takes a share of each buyback. a lower slice moves the break even back down, so the owner lowers `buybackSlice` as the coin price falls.

the launch price is the pool tick recorded in step 8 (175,000). the tick is the log of coin per eth, so a price fall of a share f of the launch price is a tick rise of ln(1 / (1 - f)) / ln(1.0001):

| coin price against launch | pool tick at or above | `buybackSlice` |
|---|---|---|
| launch | 175,000 | 0.5 eth |
| fall of 90 percent | 198,028 | 0.2 eth |
| fall of 98 percent | 214,123 | 0.1 eth |

weekly: run the postflight (step 8 command, with `SETTINGS_CHANGED=1` once the settings changed) and read the `tick` in the detail of the row `pool: start tick equals the config while nothing was bought`. compare it with the table. when it is at or above a row, set the slice of that row, the dry run first and then the send (0.2 eth is `200000000000000000` wei, 0.1 eth is `100000000000000000`):

```sh
CORE=0x... SET_buybackSlice=200000000000000000 forge script script/SetSettings.s.sol --rpc-url $MAINNET_RPC_URL
CORE=0x... SET_buybackSlice=200000000000000000 SEND=1 forge script script/SetSettings.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger
```

the dry run prints the before and after table; read it, then send. `--slow` makes forge wait for each receipt, which the delegated owner account needs (changing settings after launch, above). when the price recovers the owner may raise the slice again, up to 1 eth, with the same command.

### owner doors, locks and the handover

there is no timelock. every owner door works at once and logs an event.

trust: with no delay the owner key controls everything at once. it can point the balance module at a contract that returns dust and take every statement, swap the controller and sell every statement at the hard floor, lower the hard floor to its bound, and overpay for credits as documented above. a stolen owner key means the whole engine at once. the owner chose this because the system is new and must adapt fast, and changes are announced off chain. holders trust the owner key fully. use a multisig as owner, and close each door with its lock once it is final.

| door | effect | event |
|---|---|---|
| `setController(address)` | replaces the controller, never zero. reverts `Locked("controller")` after `lockController()` | `ControllerSet` |
| `setBalanceModule(address)` | sets or replaces the balance module, see the next section. reverts `Locked("balanceModule")` after `lockBalanceModule()` | `BalanceModuleSet` |
| `setRoyaltyBps(uint16)` and `setRoyaltyRecipient(address)` (on the controller) | the royalty share (0 to 1000) and the address `claimRoyalty()` pays (never zero), at once. `claimRoyalty()` is open to anyone and reverts `ZeroAmount` while nothing is owed | `RoyaltyBpsSet`, `RoyaltyRecipientSet`, `RoyaltyClaimed` |
| `releaseRedeemBurn(uint256 amount)` | moves up to `amount` of `ethRedeemBurn` into `ethToBuyback`, capped at the reserve, reverts `ZeroAmount` when the reserve or `amount` is 0. the eth stays in the Core for the coin buyback. callable after `migrate` | `RedeemBurnReleased` |
| `addAdapter(address)`, `removeAdapter(address)` | approved `buyListing` adapters. forbidden addresses are refused on add. an add reverts `Locked("adapters")` after `lockAdapters()`, a removal always works | `AdapterSet` |
| `setAllowedRecipient(address,bool)` on `SeaportBasicAdapter` | the recipients of additional payouts the Seaport adapter accepts. owner of the Core only | `RecipientSet` |
| `setSettings(Settings)`, `setRate(uint256)` | as in the section above. never lockable | `SettingsSet`, `RateSet` |
| `setCreditCostToPotBps(uint16)`, `setChosenComposeOn(bool)`, `setMinCcToChoose(uint96)` | the Core credit settings (the `credit` block of the config). at once, never lockable | `CreditCostToPotBpsSet`, `ChosenComposeOnSet`, `MinCcToChooseSet` |
| `setSuccessor(address)` | the contract that `migrate` sends the assets to: zero or an address with code. unset at launch. reverts `Locked("successor")` after `lockSuccessor()` | `SuccessorSet` |
| `migrate(maxCredits)` | the first call retires the Core (`retired()`, `Retired` from `sellForEth`, `buyListing`, `sellForBalance`, `adopt`, `compose` and `composeChosen`). moves `ethPot`, `balancePot` and credits to the successor in batches, see the next paragraph. `ethToBuyback`, `ethRedeemBurn` and the held statements stay in the Core. a balance token `transfer` that fails (reverts, returns false) leaves `balancePot` in the Core and the other legs go on. reverts `NoSuccessor` while the successor is zero | `EngineRetired` once, `Migrated`, `BalanceTokenMigrationSkipped` |
| `rescueNft(token, id, to)` | takes a stuck NFT out: a credit not in the pile, a statement the books do not hold, any other ERC721 the Core holds. reverts `InPile`, `Held`, `NotHolder` | `NftRescued` |

the four one way locks: `lockController()`, `lockBalanceModule()` (reverts `NoBalanceModule` while the slot is empty, so the balance side cannot be locked out by accident), `lockAdapters()` and `lockSuccessor()`. each is irreversible and logs `ControllerLocked`, `BalanceModuleLocked`, `AdaptersLocked` or `SuccessorLocked`. the settings and the sale settings of the controller stay open after all three. a controller that was locked in can still be tuned through its own owner doors, but not replaced. lock a controller only after it is proven in use: one that was locked while it reverts, burns its gas or answers short can never be replaced, and then `compose` reverts for good and `redeemStatement` reverts `NotEligible`, because the redemption gate reads the controller's `atFloor`.

the successor is unset at launch and `lockSuccessor()` is a later decision. the successor can be set at any time before the lock, so the lock waits until the next engine is chosen or until no migration is wanted any more. before `lockSuccessor()` with a successor set, dry run `migrate` against it: on a fork of the latest block (`anvil --fork-url ... --auto-impersonate`, then `cast send $CORE "migrate(uint256)" 150 --from $OWNER --unlocked`) or with `cast call $CORE "migrate(uint256)" 150 --from $OWNER`, and check that it does not revert (a successor that rejects eth makes it revert `CallFailed`) and that `Migrated` shows the eth, balance token and credits it should. a successor locked in without this check can leave `migrate` reverting with no way to set another successor, because the lock closes `setSuccessor`. `lockSuccessor()` with the successor still zero disables `migrate`. `migrate` transfers eth, balance token and credits. the statements stay in the old Core, which sells them out itself, and a statement leaves only through `buy` or `redeemStatement`, so the balance module stays set and working on the old engine until its held list is empty: `buy` sells held statements and books the proceeds, and `redeemStatement` redeems statements. `buyback()` there burns the `ethToBuyback` that stayed and reverts `NothingToBuy` while `ethToBuyback` is 0. a later `migrate` moves the pot share of what was booked. `migrate` is called repeatedly with a batch size that fits the transaction cap (`maxCredits` bounds the credits moved per call and costs about 44,800 gas per credit plus 159,000 for the pots: 150 uses about 6.9 million gas and 370 is the largest value under the cap, FLOW 10.10; the per credit figure was measured before decision 92 with credits in two piles and `test_GAS_migrateOneSixtyCredits` logs the current one): the first call moves all of `ethPot` and `balancePot`, later calls move the rest. `maxCredits` 0 moves the pots only. a failed balance token transfer logs `BalanceTokenMigrationSkipped(successor, amount)` and `Migrated` shows 0 balance tokens: `balancePot` stays and the next `migrate` retries it. the first call retires the Core, so a pile that a partial batch leaves behind can only be migrated by later calls. the next call moves what arrived since.

the owner handover has two steps: `transferOwnership(address to)` from the owner records `pendingOwner` (`OwnershipTransferStarted`), then `acceptOwnership()` from `to` makes it the owner (`OwnershipTransferred`). passing the zero address clears a pending handover. there is no renounce. move the owner to a multisig this way, check that the multisig can send a transaction (accept from it) before relying on it. `ControllerV1` reads the live owner of the Core, so its sale settings follow the handover.

### the sale controller

`ControllerV1(core, sale, credit)` prices statements and pile credits. the `sale` tuple is `(markupBps, startCapBps, fastDecayBpsPerHour, kneeBps, slowDecayBpsPerHour, anchorHalfLife, anchorMinCost)`, launch `(15000, 100000, 100, 10000, 25, 604800, 100000000000000000)`. the controller keeps the anchor, the running level of sale prices in bps of the price reference, 10000 at launch. the price reference of a statement is `max(cost, valueOf(rating))` (`referenceOf(sid)`): the larger of its cost and `valueOf(rating)`, computed at each call, where `valueOf(points)` is the larger of `floorRate * points / refScore` and the balance token pool term (`points * unitPerPoint` at the pool price, 0 until the owner sets the pool key and a module). the floor rate is the larger of the climbed eth bid rate and the remembered peak, so a sale within the block, which lowers only the rate, cannot push the reference down. `refScore` (4330000 at launch) is the per-credit score in ten-thousandths of a point. the anchor moves up with sales and down with time: `anchorBps()` is `10000 + (storedAnchorBps - 10000) * 2^(-(now - anchorTime) / anchorHalfLife)`. the start price is `startBps() = min(anchorBps() * markupBps / 10000, startCapBps)`. the asking price of a statement with reference `r` falls from `start` at `fastDecayBpsPerHour` bps of `r` an hour until it reaches `kneeBps`, then at `slowDecayBpsPerHour` an hour down to `saleFloorBps` of `r` (the Core setting that is also the Core's floor on cost), changing every second. a start at or below `kneeBps` falls at the slow rate from compose. it is computed from the age of the statement (time since its compose), the anchor now and the current settings at each call, so a held statement follows the anchor and every setting change applies to it at once. owner doors, at once, each with an event: `setMarkupBps(uint16)` (10000 to 40000, at most `startCapBps`), `setStartCapBps(uint32)` (the larger of `markupBps` and `kneeBps` to 200000), `setFastDecayBpsPerHour(uint16)` (1 to 10000), `setKneeBps(uint32)` (1000 to `startCapBps`), `setSlowDecayBpsPerHour(uint16)` (1 to 10000), `setRefScore(uint32)` (1 to 8000000), `setAnchorBps(uint32)` (10000 to `startCapBps`, corrects the anchor and restarts its decay), `setAnchorHalfLife(uint32)` (1 day to 90 days, stores the anchor now first), `setAnchorMinCost(uint128)` (0 to 10 ether, the least statement cost in wei whose buy moves the anchor). the owner is the Core owner, read live. `setPaused(bool)` is a Core door (section 4, below).

sales. `buy(uint256 sid)` pays at least `priceOf(sid)` and gets the statement through `Core.sellTo`, the excess is refunded. a sale price in bps of the reference (the curve price, rounded up) above `anchorBps()` moves the anchor to the mean of the anchor now and the sale price, at most `startCapBps`, and the controller emits `AnchorMoved(sid, saleBps, anchorBps)`. a sale at or below the anchor leaves it unchanged. the Core floor `saleFloorBps` of cost binds whatever the controller says, so a low controller price cannot sell below it, and a price change reaches every held statement at once.

credit sale window. the credit part of the constructor is the `credit` tuple `(costToPotBps, chosenComposeOn, minCcToChoose, saleOn, window, floorBps, startBps, refScore)`, launch `(10000, false, 1000000000000000000, false, 14400, 11000, 30000, 4330000)`; the controller reads the last five. `creditSaleOn` is false at launch. while it is true every pile credit is for sale from its acquisition time: `creditPrice(id)` falls in a straight line from `start` to `floor` over `creditWindow` and rests at `floor`, with `floor = max(cost, baseline, backstop) * creditFloorBps / 10000` and `start = floor * creditStartBps / 10000`. `baseline` is the credit's score times the lower of the stored and the live `unitPerPoint`, priced at the balance token pool key, and only lifts the floor: it is 0 while the pool key or the balance module is unset, the pool price reads zero or the live unit read fails, and the sale never reverts for a missing or failed pool read. `backstop` is `core.floorRate()`, the larger of the climbed eth bid rate and the remembered peak, times `max(1, score / refScore)`. `buyCredit(id)` and `buyCredits(ids)` (payable) revert `CreditSaleOff` while the sale is off and `Paused` while sales are paused, and refund the excess. compose waits for the window while the sale is on: `nextPage()` is ready once the newest of the 80 oldest credits has been in the pile for `creditWindow`. owner doors, at once, each with an event: `setCreditSaleOn(bool)`, `setCreditWindow(uint32)` (60 to 2592000 seconds), `setCreditFloorBps(uint16)` (10000 to 40000), `setCreditStartBps(uint32)` (10000 to 200000). turning the sale on: `setCreditSaleOn(true)`, then read `creditPrice(id)` for a pile credit and `lens.snapshot().creditSaleOn`. set the balance token pool key when you want the baseline to lift the floor (it is 0 without it); the sale works whether or not the key is set.

chosen composition. `core.composeChosen(ids, format)` composes 80 pile credits of the caller's choice with the art format 0 to 7. it is off at launch (`chosenComposeOn`): `setChosenComposeOn(true)` opens it, `setMinCcToChoose(amount)` sets the least coin balance of its caller (1 coin at launch). the same balance gates `setHeldFormat(sid, format)`, which sets the format of a held statement. the sign off row `signoff: chosen composition` prints the value in base units. every named credit must be past its window while the credit sale is on.

verify args of the controller: `cast abi-encode "constructor(address,(uint16,uint32,uint16,uint32,uint16,uint32,uint128),(uint16,bool,uint96,bool,uint32,uint16,uint32,uint32,uint16,address))" $CORE "($(jq -r '.sale | [.markupBps,.startCapBps,.fastDecayBpsPerHour,.kneeBps,.slowDecayBpsPerHour,.anchorHalfLife,.anchorMinCost] | map(tostring) | join(",")' $LAUNCH_CONFIG))"`.

### when the balance token's auction is announced

`core.setPaused(bool)` stops `sellTo` and `sellCreditTo` and holds the price age of every held statement. owner runbook:

1. `core.setPaused(true)`. read back `core.paused()` and the `PausedSet(true)` event. from this block `buy`, `buyCredit` and `buyCredits` revert `Paused()`, `priceOf` still answers, and composing, the eth bid, redemptions, buybacks and fees run as before.
2. re-price with the live sale settings while paused: `setAnchorBps` (10_000 to `startCapBps`, restarts the anchor decay), `setMarkupBps` and `setKneeBps` on the controller, and `saleFloorBps` through `setSettings`. read `priceOf(sid)` for a few held statements and `startBps()` after each change. the price age is held, so a held statement resumes at the age it had at the pause. a statement composed during the pause starts aging at the resume. the anchor keeps decaying with wall time in the pause.
3. `core.setPaused(false)` when the prices are ready. read back `core.paused()`, `PausedSet(false)` and `priceOf(sid)`.

a `setPaused` call that repeats the current state changes nothing and emits nothing. postflight shows the row `core: not paused` as a warning (`SETTINGS_CHANGED=1`) while sales are paused.

### turning on the balance side: the balance module, the mode and the unit

`redeemOn` and `balanceBidOn` are false at launch (decisions 82 and 107): no redemption and no balance token bid. statements stay statements, sellable for eth through `buy` (or paused, above) and redeemable once the owner turns the balance side on. the owner decides the redemption policy later. redemption could close (ARCHITECTURE section 14).

the balance side has two owner controls, both through `setSettings` and effective at once: the switches `redeemOn` (redemptions run) and `balanceBidOn` (the balance token bid runs), and the balance module (`setBalanceModule`). a redemption needs a module and `redeemOn`; the balance token bid needs a module and `balanceBidOn`.

eligibility is the controller's `atFloor`: a statement may be redeemed once its curve price has reached its floor (`saleFloorBps` of its price reference), not after a fixed time. a redemption owes `rating * unitPerPoint * (10000 - redeemSlippageBps) / 10000` balance token, where `rating` is the statement's stored rating and `unitPerPoint` is read from the module in the call. all redeemed balance token goes to `balancePot`; each redemption also moves `redeemBurnBps` of `ethRedeemBurn` into the coin buyback. the owner can move the reserve into the coin buyback at any time with `releaseRedeemBurn(amount)`, so it is not stranded while `redeemOn` is false.

`setBalanceModule` may run any number of times until `lockBalanceModule()`, each at once. a later module must report the same `balanceToken()` (else `BalanceTokenChanged`). `unitPerPoint` is validated at every set (non zero, at most `uint128`, else `BadModule`) and read from the module at every use, so a rate change of the module needs no owner call. after `lockBalanceModule()`, `setBalanceModule` reverts. a set clears the allowed target flag of the module; pots, piles and held statements are untouched.

the balance token bid (`sellForBalance`, `balanceBidOn`) pays `score * unit * (10000 - balanceBidMarginBps) / 10000` per credit, where `unit` is the module's `unitPerPoint()` read in the call, reading each live credit's score from the CreditScore contract. a unit read that fails, returns short or is zero reverts the bid. the credit enters the single pile with an eth cost basis of the floor rate (the remembered peak of the eth bid or the climbed price state) times `score / refScore`, at least 1 wei. it reads no pool, so the bid needs no pool key and records the same basis whatever the pool price.

runbook:

1. decide the two switches (`redeemOn`, `balanceBidOn`) and set them with `setSettings`.
2. call `setBalanceModule` with the module. read back `balanceModule()`, `balanceToken()`, `unitPerPoint()` and the `BalanceModuleSet` event.
3. a unit change of the module applies at once to the next redemption, bid and price. a redemption owes `rating * unitPerPoint`, so a rise raises what a redemption must return; adjust `redeemSlippageBps` if needed.
4. decision 87: when the balance token's uniswap v4 pool exists, set the controller's pool key with `ControllerV1.setBalancePoolKey`. the key floors a statement's asking price at its redeemable value in eth and lifts the credit sale baseline. the balance token bid and the credit sale both work without the key (the bid records the peak backstop, the credit baseline is 0), so the key is not an ordering gate for either; set it in any order with `setBalanceModule` and `setCreditSaleOn`.
5. lock the module with `lockBalanceModule()` only once the module is final. after the lock the module and the balance token cannot change; a rate change of the module still applies at once.


## 5. what cannot change after launch, and the v2 surface

fixed for the life of the pool, by the artcoins contracts. the owner as coin admin can repoint the recipients named in the rows below:

| fixed | why it matters |
|---|---|
| the baseline skim (6.9 points of volume), `bountyBps` (9638), the lp fee (0), the referral cap (0), the sniper schedule (90 points falling to the baseline over 30 minutes) | set in the hook's skim config and the mev module schedule when the pool is created. a trader's total cost is fixed |
| the bounty recipient is the Core at launch | the hook pays the bounty leg to the Core. the owner as coin admin can repoint the hook bounty recipient with `setBountyRecipient(poolId, recipient)` until `coin.lockRecipients()`, which freezes it (renouncing the admin freezes it too). a new Core takes over the fee stream this way, which is how a later engine migrates, so do not call `coin.lockRecipients()` while a migration is possible |
| the launch position (one position, the full range from the start tick) and the locker reward slots (the creator slot and the protocol slot) | set by the locker at the launch. the position cannot be moved or widened. the owner as coin admin can repoint the creator slot recipient with `setRewardRecipient` until `coin.lockRecipients()`, and the protocol slot stays with the launcher protocol |
| the protocol leg of the skim (362 of 10,000 of the skim, the complement of `bountyBps` 9,638, the factory floor share) | belongs to the launcher protocol and its recipient. it is a separate business from this engine and its owner, it is never the engine's or the owner's income, and nothing here changes it |
| the locker protocol slot (`protocolBps` 2000) | a reward slot of the lp fees: 2000 of 10,000 of the lp fees go to the launcher protocol and the creator slot takes the rest. at lp fee 0 the slot is empty. the slot recipient is not repointable |
| the coin: name, symbol, supply, canonical hook and pool, the pinned allowlist seeds (the locker and the escrow) | immutable in the token. the Core is off the allowlist (decision 29) and the owner may add or remove entries as token admin until `lockAllowlist()` |
| the Core: its stack addresses and the coin (immutables), `SUPPLY`, the rate bounds, the linked `CoreLib` | the Core is not upgradeable. a different stack is a new Core. its address is the CREATE2 address of the config and the deployer |

changeable by the owner until the one way locks: the settings and the rates (never lockable), the controller (`lockController`), the balanceModule (`lockBalanceModule`), the approved adapters (`lockAdapters`), the successor of `migrate` (`lockSuccessor`), the coin allowlist (`coin.lockAllowlist`), the pool bounty recipient and the creator reward slot recipient (`coin.lockRecipients`). eth, credits, statements and balanceToken leave the Core through its own sales and redemptions, and eth, credits and balanceToken also, until `lockSuccessor()`, through `migrate` to the successor; coin leaves through the buyback burn and `rescueCoin`; an NFT the books do not hold leaves through `rescueNft`. irreversible once taken: each lock, `coin.lockAllowlist`, `coin.lockRecipients`, `coin.unrestrict`, `coin.renounceAdmin`. a handover of the Core or the coin admin to a multisig is not a lock, and each can be accepted back.

what the system calls on v2 (local copies in `src/interfaces/ArtCoinsV2.sol`, contract sources of v2 repo commit d4aa46b, equal to the live stack). a different stack means new addresses, new pins and a diff of these first:

| contract | calls |
|---|---|
| factory | `deployTokenAsOwner(DeploymentConfigV2,uint16)`, `predictToken(address,DeploymentConfigV2)`, `owner`, `deprecated`, `deployFee`, `minProtocolSkimShareBps`, `setMinProtocolSkimShareBps` (owner command), `enabledHooks`, `enabledLockers`, `enabledMevModules`, `defaultAllowed`, `protocolRecipient`, `tokenDeployer`, `isCoin`, `deploymentInfo`, `defaultProtocolFeeBps`, `poolManager` |
| hook | `poolInfo`, `skimConfig`, `globals`, `isLauncher`, `constantsHash` |
| token | `restricted`, `allowlistLocked`, `recipientsLocked`, `description`, `isAllowed`, `isPinned`, `admin`, `launcher`, `canonicalHook`, `canonicalPoolId`, `poolManager`, `burn`, `burnFrom` |
| locker | `tokenRewards`, `collectRewards`, `isLauncher`, `feeEscrow` |
| fee escrow | `claim`, `isDepositor`, `isCoreDepositor`, `balances` |
| mev module | `schedule`, `currentSkimBps`, `windowEnd`, `hook` |

behaviour the Core relies on: the hook pushes the bounty to the Core with 2,300 gas, and the Core's `receive` only compares the sender; on a restricted coin the hook grants the transient allowance each canonical swap needs, so a buyback burns what it buys in the same call; the bounty bps applies to the baseline skim only, the whole sniper extra goes to the bounty recipient.

what is left before the broadcast: the `setMinProtocolSkimShareBps(362)` command (step 3), funding the owner for the deploy fee and gas, the dry run and the broadcast against the live stack, etherscan verification, and the postflight and a first `book` on real state. preflight requires `STACK_VERSION()` 2 on the factory, the same `constantsHash()` across the stack and the code hash of each contract the launch reaches. the live runtime code equals the d4aa46b ci build at every byte except the immutable slots, so the code hashes identify the d4aa46b build.

## 6. when a transaction fails half way

`Deploy` sends, in order: the library, the core, the controller, the lens, the two listing adapters, `setController`, `addAdapter` for each adapter, then the launch through the factory. every state between them is safe: the library is stateless, the controller, the lens and the adapters are inert until the Core points at them, and a Core without a controller or an adapter holds nothing and refuses its controller doors. nobody else can launch to the predicted coin because the coin address depends on the sender (`predictToken(sender, config)`) and `deployTokenAsOwner` is owner only. every address is a CREATE2 address, so a rerun creates nothing twice.

first read what is on chain (`export CORE=...`, the address `Deploy` printed or the transaction named Core in `broadcast/Deploy.s.sol/1/run-latest.json`):

```sh
cast code $CORE --rpc-url $MAINNET_RPC_URL | head -c 12    # 0x... means the core exists
export COIN=$(cast call $CORE "COIN()(address)" --rpc-url $MAINNET_RPC_URL)
cast code $COIN --rpc-url $MAINNET_RPC_URL | head -c 12    # 0x means the launch is not sent
```

| failure point | state on chain | recovery |
|---|---|---|
| 0. nothing or only the library sent | the library on chain, stateless | rerun `Deploy` (the library is skipped and the addresses are the ones preflight prints now) |
| 1. core sent, launch not sent (`cast code $COIN` empty) | the core, and some of the controller, lens, adapters and owner calls. the core holds 0 | `Resume`. it creates what has no code and sends the owner calls and the launch that are not on chain. needs the factory fee in the owner's balance |
| 2. launched | as in the config | `Resume` refuses (`AlreadyLaunched`) |

the script reads the chain and sends only the missing steps, then runs postflight. run it as the same signer (`DEPLOYER` set, the script refuses another signer) with the same config and `CONFIG_HASH`:

```sh
CORE=$CORE DEPLOYER=$DEPLOYER CONFIG_HASH=$CONFIG_HASH forge script script/Resume.s.sol --rpc-url $PRIVATE_RPC --broadcast --slow --ledger
```

it refuses to run when `$CORE` is not the Core address of this config and deployer (`CoreMismatch`), when there is no Core there (`NotStarted`, run `Deploy`), when the coin is launched already (`AlreadyLaunched`), when the signer is not the factory owner, or when the preflight rows for the factory fail. it also refuses while `SETTINGS_CHANGED` or `COIN_CHANGED` is set: each turns failed rows into warnings, so a stale flag in the shell would skip a check. only `Postflight` honors them. a deploy that the owner changed before it was finished is completed by hand with the list below.

the same by hand, as the owner, if the script cannot be used. each is the single transaction of that point, in this order:

```sh
# point 1: send the saved launch transaction (the calldata is in the broadcast file) with the live fee
export LAUNCH_INPUT=$(jq -r '[.transactions[] | select((.function // "") | startswith("deployTokenAsOwner"))][0].transaction.input' broadcast/Deploy.s.sol/1/run-latest.json)
cast send $FACTORY $LAUNCH_INPUT --value $(cast call $FACTORY "deployFee()(uint256)" --rpc-url $MAINNET_RPC_URL) --rpc-url $PRIVATE_RPC --ledger
```

then run step 8 (postflight). after a failed launch transaction the Core is still valid, so a retry of that one transaction is right. the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json` is gitignored and holds the signed data, keep it private.

a transaction pending or dropped in the relay: compare `cast nonce $DEPLOYER --rpc-url $MAINNET_RPC_URL` with `cast nonce $DEPLOYER --block pending --rpc-url $MAINNET_RPC_URL`. when they differ a transaction is still pending, wait for it. if the relay dropped it, the nonce does not move and the state is the one the table reads, resume from it. never rerun the whole script while one is pending.
