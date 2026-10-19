# audit: deployment and operations scripts (commit 84ea170)

scope: script/*.sol, script/deploy.sh, script/env, script/config, script/tools, script/dev, .github/workflows, docs/RUNBOOK.md sections 0 to 7. ground truth: src/**, the compiled `out/` (solc 0.8.30+commit.73712a01, via_ir), the mainnet fork at 127.0.0.1:8545 (block 26222700) and mainnet head via https://eth.drpc.org (block 26223305). nothing under /home/user/cc was modified; no forge build/test, no anvil started. every number below was read or computed in this session.

## findings

### S-01  STACK=master is incoherent with the current pins (the fixture cannot pass preflight)
severity: medium. category: launch readiness, legibility.
files: script/LaunchConfig.sol:18-34, script/Checks.sol:558-575 (`_preStackCode`), script/config/v2-master.json:43-56, docs/RUNBOOK.md:254-258.

claim: the nine `V2_CODEHASH_*` pins and `V2_CONSTANTS_HASH` are the live mainnet stack's values, but `_preStackCode` applies them unconditionally, and four of the master fixture's recorded hashes differ, so `STACK=master` fails at least four `code hash:` rows. the comment above the pins says the opposite.

evidence:
- LaunchConfig.sol:18-24: "the `constantsHash()` the master v2 stack reports ... the runtime code hashes ... of the master v2 stack contracts ... script/config/v2-master.json holds the addresses and these hashes".
- `cast keccak $(cast code ...)` at mainnet head: hook `0x6778…ebdc`, factory `0xc81a…0c65`, locker `0x191e…386a`, escrow `0xeb55…9975`, mev `0xe3bf…dc80`, tokenDeployer `0xaf39…b043`, allowlist `0x7a98…18c4`, feeController `0x33ac…5bae`, burnRouter `0x446c…edd9`, hook `constantsHash()` `0x1b7d…23d0`. every one equals the pin in LaunchConfig.sol:20-34 (V2_PIN_BLOCK 26205064).
- v2-master.json `codeHashes`: hook `0x09eecbc3…`, mevModule `0x571d7cd9…`, tokenDeployer `0x850c232a…`, feeController `0xcb35ea27…` differ from the pins; factory, locker, escrow, allowlist, burnRouter are equal.
- Checks.sol:558-575: `_pin("hook", s.hook, V2_CODEHASH_HOOK)` ... `_pin("protocol fee controller", controller, V2_CODEHASH_FEE_CONTROLLER)`; the only master branch is the treasury row (line 571-573). `_preStackVersion` compares the master hook's `constantsHash()` with the live `V2_CONSTANTS_HASH` as well.
- RUNBOOK.md:258: "The dump is tracked so CI can load it (`.github/workflows/ci.yml` and `candidate.yml` start an anvil from it)". neither workflow mentions `STACK`, `stack-master` or `anvil_loadState`; both fork live mainnet at `latest - 100` (ci.yml:217-223, candidate.yml:41-47).

failure scenario: an operator follows RUNBOOK section 7 ("STACK=master points the fixture, the scripts and the local end to end at this record") and `script/deploy.sh local` dies in preflight with `code hash: hook is the live v2 contract`, `code hash: mev module …`, `code hash: token deployer …`, `code hash: protocol fee controller …` (and probably `v2: hook constantsHash equals the pinned live value`). the 468 kB tracked dump `stack-master-26158000.hex` and `_applyStackSelector` are dead weight that still reads as a supported path.

structural fix: either delete the master selector (`_applyStackSelector`, `_master()`, the dump, v2-master.json, RUNBOOK "master stack fork fixture") since the stack is live, or make the pins a per-stack record (read the `codeHashes` and a recorded `constantsHash` from the selected v2-*.json) and add `test/Config.t.sol` rows that assert each pin equals the record. fix the LaunchConfig.sol comment either way.

### S-02  the default fork block of the dev tooling predates the live stack
severity: medium. category: launch readiness (dev and CI path), legibility.
files: script/dev/anvil.sh:3,17; script/dev/local.sh:87; .env.example:4; script/tools/check-preflight.sh:37,59; docs/RUNBOOK.md:225; README.md:46.

claim: with `STACK=live` (the default since the stack shipped) every default of 26158000 forks a chain where the factory `0xC27e182e…` does not exist (v2-mainnet.json `factoryDeployBlock` 26202473), so `script/dev/e2e.sh`, `script/dev/local.sh` and `script/tools/check-preflight.sh` fail out of the box.

evidence: anvil.sh:17 `FORK_BLOCK="${FORK_BLOCK:-26158000}"` and :3 "forks mainnet at the pin block"; local.sh:87 same default; .env.example `FORK_BLOCK=26158000`; check-preflight.sh:59 `block="${FORK_BLOCK:-26158000}"`; candidate.yml:119 had to pass `FORK_BLOCK=26208025` explicitly to `local.sh`; ci.yml:217-223 forks `latest - 100` and never uses anvil.sh. RUNBOOK.md:225 "an anvil fork of block 26158000 (chain id 31337) with the system deployed by the launch scripts".

failure scenario: `cp .env.example .env` (README) and `forge test --match-path test/<fork test>` or `script/dev/local.sh` → Core constructor `NoCode(factory)` / preflight `code hash:` rows fail; an engineer reads this as a regression.

structural fix: one default in one place (`FORK_BLOCK` default `head - 100`, or a single tracked `script/config/fork-block` value at or after 26208025) consumed by anvil.sh, local.sh, check-preflight.sh, .env.example and the RUNBOOK text.

### S-03  RESUME=replay and RESUME=record discard the preflight result
severity: low to medium. category: security (guard bypass by design), launch readiness.
file: script/deploy.sh:258-262, 308-331.

claim: under any `RESUME` the wrapper runs preflight only to harvest `CONFIG_HASH`; a nonzero exit is ignored. `RESUME=state` (and LAUNCH_ONLY) re-enforces `preflightResume` inside Resume.s.sol (SystemResumer.sol:256-263), but `RESUME=replay` sends the saved transactions (including the launch) and `RESUME=record` writes the record with no re-check of the stack code hashes, `deprecated()`, the deploy fee cap, the owner delegation or the live supplies between the kill and the replay.

evidence: deploy.sh:258 `if [ "$PRE_RC" != 0 ] && [ -z "$RESUME" ]; then ... guard "preflight failed: ..."` with no else branch; deploy.sh:323 `forge script script/Deploy.s.sol "${BFLAGS[@]}" --resume` (forge's `--resume` does not re-run `run()`, so none of `Deploy.run`'s checks execute); the intended exemption is only the three prediction rows (`predicted core is empty`, `predicted renderer is empty`, `predicted coin is empty`).

failure scenario: between a killed run and the replay the artcoins owner changes the factory's `tokenDeployer` or treasury, or the deploy fee rises above 0.1 ether. the saved `deployToken` transaction still lands (fee is taken from the saved `value`, which is the old fee; a raised fee reverts, a changed token deployer does not).

structural fix: in replay and record compare the `failed:` list with the allowed set (the three prediction rows) and `guard` on anything else, as the LAUNCH_ONLY path already does through `launchOnlyChecks`.

### S-04  SetSettings prints a `cast send` fallback that cannot encode (37 types for 39 fields)
severity: low. category: legibility, best practice.
files: script/SetSettings.s.sol:47-48, 71, 316-325; script/dev/check-post.sh:370-376; docs/RUNBOOK.md:86.

claim: `TUPLE` has 37 types; `Settings` has 39 fields (`buyToArtistBps`, `balanceDiscountBps` appended, SettingsFields.sol:336 `N = 39`); `_tuple` prints 39 values, so the printed `cast send $CORE "setSettings(<37 types>)" "(<39 values>)"` command is rejected by cast. `_tuple` prints `valueModeOn` (index 36) as `0`/`1` while indices 11 and 12 print `true`/`false`. the script's own broadcast uses `abi.encodeCall` and is correct.

evidence: TUPLE split on commas = 37 (counted); `awk '/^struct Settings/,/^}/'` on Interfaces.sol lists 39 typed fields, last two `uint16 buyToArtistBps; uint16 balanceDiscountBps;`. check-post.sh `SIG` is the same 37-type tuple and reads `.[0][11]`, `.[0][12]`, `.[0][36]`; it works only because cast tolerates the two trailing words. RUNBOOK.md:86 "`Settings` has 37 fields in five storage slots".

failure scenario: an operator in an incident pastes the printed command (RUNBOOK section 4 "lowering the spend cap in an incident") and gets an encoding error instead of a transaction.

structural fix: derive the tuple string from `SettingsFields` (or a `type(Settings)` string pinned by a test against `vm.parseJson` of the ICore ABI) and print every bool the same way; update RUNBOOK and check-post.sh.

### S-05  "lp fee 0" and the protocol leg are signed off but not read back
severity: low. category: launch readiness.
files: script/PostflightPool.sol:467-476 (`_postState`), 397-400 (`_postSkim`), script/Checks.sol:807-820 (signoff text).

claim: the signoff rows print `lp fee 0` and "the protocol leg ... lands at the launcher protocol fee controller", but postflight only checks `poolKey.fee == 0x800000` (the dynamic flag) and discards slot0's `lpFee` (`(uint160 sqrtPrice, int24 tick,,) = getSlot0(...)`), and the protocol recipient row is a `_warn`.

evidence: PostflightPool.sol:468 drops the third and fourth return values; :399 `_warn("warn: protocol recipient equals the factory protocol recipient", ...)`; the hook sets the dynamic lp fee at pool init and the engine never reads it.

failure scenario: a hook version that initialises a nonzero dynamic lp fee would pass postflight, and the launch economics (621 / 69 bps of volume) would be off by the lp fee with no row saying so.

structural fix: read `lpFee` from slot0 and `_check` it is 0; promote the protocol recipient row to `_check` (COIN_CHANGED soft) since the signoff text states it.

### S-06  the 22,000,000 gas budget is asserted by a gate that has not run on this candidate
severity: low. category: launch readiness.
files: script/Checks.sol:50-53, test/Rehearsal.t.sol:216-218, docs/STATUS.md section 4 and 6.

claim: `DEPLOY_GAS_ESTIMATE = 22_000_000` is enforced only by `test/Rehearsal.t.sol` (`assertLe(total, DEPLOY_GAS_ESTIMATE)`), and the freeze table has every gate `pending` ("the former 19,069,638 gas result covered eleven transactions and is historical"). the preflight balance row prices the deploy at `fee + DEPLOY_GAS_ESTIMATE * block.basefee` (Checks.sol:620) with no priority fee.

evidence: runtime sizes from `out/` (masked hashes computed in this session): Core 23,674 B, CoreLib 23,635 B, CoreOpsLib 3,378 B, ControllerV1 17,189 B, SeaportBasicAdapter 2,536 B, CreditStrategyAdapter 534 B, LogoCoinRenderer 4,464 B. code deposit alone (200 gas/byte) is 15.1M; with creation calldata, constructor execution and the four owner calls the eleven non-launch transactions are about 17M, which leaves roughly 5M for `deployToken` under the budget. each transaction is far under 16,777,216 (`_step` reverts `TxOverGasCap` above cap minus 520,000; libraries are not measured by `_step` but are about 5.2M and 0.8M). the owner holds 81,556,823,473,042,614 wei (0.0816 ETH) at head, which covers 22M gas only up to about 3.7 gwei base fee; `deployFee()` is 0.

failure scenario: the launch transaction measures above about 5M and the frozen candidate rehearsal fails `assertLe`, or the balance row passes on a quiet morning and the broadcast stalls on a base fee spike because the budget ignored the priority fee.

structural fix: run the rehearsal gate on the candidate and re-pin the budget from the measured twelve-transaction total plus margin; price the balance row at `basefee + a pinned priority fee`.

### S-07  SPEC section 12 (an authority document) still instructs a removed factory step and names a removed function
severity: medium for legibility (SPEC outranks code in AGENTS.md). category: legibility.
files: docs/SPEC.md:259, docs/RUNBOOK.md:23.

claim: SPEC 12 says "Before the launch the factory owner lowers `minProtocolSkimShareBps` to 1,000" and "`lockRecipients` is a later owner decision". RUNBOOK step 3 says the deployed factory "has no `minProtocolSkimShareBps` and no setter for it ... `setMinProtocolSkimShareBps(uint16)` reverts", and decision 126 removed both; the coin's lock is `lock()` (Lock.s.sol:310 `t.lock()`).

failure scenario: an operator reconciling the runbook against the spec (AGENTS.md authority order) attempts a reverting owner call or waits for a step that cannot happen.

structural fix: rewrite the two sentences of SPEC 12 to decision 126 and 160 wording; see the stale table below for the RUNBOOK occurrences.

### S-08  `anvil:keystore` is accepted on a chain id 31337 node while forge signs for chain id 1
severity: low. category: best practice (a guard that lets a run fail late). file: script/deploy.sh:94, 232, 275.

claim: `case "$NODE:$WALLET" in anvil:unlocked|anvil:keystore|live:keystore)` accepts a keystore on anvil at the env default `CHAIN_ID=31337` (rehearsal.env:6), while every forge invocation carries `--chain-id 1`, so a keystore signature carries chain id 1 and a 31337 node rejects the transactions after the build, preflight and signoff have run. the only working keystore rehearsal is the one rehearse-signer.sh sets up (`CHAIN_ID=1`, line 66). not executed here; inferred from the flags.

structural fix: `[ "$WALLET" != keystore ] || [ "$CHAIN_ID" = 1 ] || die "a keystore signs for chain id 1; run the anvil with --chain-id 1"` next to the pair check.

### S-09  script headers show private key invocations the wrapper refuses
severity: low. category: legibility. files: script/Deploy.s.sol:9-10, script/Resume.s.sol:68-69, script/Lock.s.sol:276, script/SetSettings.s.sol:36, docs/RUNBOOK.md:82.

evidence: Deploy.s.sol:9 "`... --broadcast --slow --private-key $KEY` (or `--account` or `--ledger`)"; deploy.sh:36-41 refuses `*private*key*` arguments and a 64 hex value, and unsets `PRIVATE_KEY`/`ETH_PRIVATE_KEY`; RUNBOOK section 0 names the keystore as the signing path and `--ledger` nowhere else.

structural fix: show the keystore form only.

### S-10  the stale "live engine occupies the predicted addresses" pin in e2e-real.sh
severity: low. category: legibility, launch readiness (it would hide a real collision).
file: script/dev/e2e-real.sh:103-106.

claim: the comment says the live protocol occupies the Core, coin and renderer CREATE2 addresses at recent head blocks and therefore pins `FORK_BLOCK` 26208025. for this build that is false, so the pin is a cache key, not a collision guard, and it hides a real collision check (a fork at head would surface one).

evidence (computed with cast from `out/` and script/config/mainnet.json, deployer = owner): CoreLib `0xFae5939A144409a2bCa8B60f94dbd5a7b94bf01F`, CoreOpsLib `0xAbcfEE48bA34760420B068BE28a15a886C574DF1`, renderer `0x0D2022F8D780884A1B46de156CBfc4f36423504c`, Core `0xA66dbb50B9D6622233F195C4d795EAA2abD59116`, controller `0x7b48F47F272E392f27A76E222a168D55D39AEb97`, coin (factory `predictToken`) `0x696f4dC78F29dd14Ad3CbD5153BbbbC5dC661b5c`; `cast code` at head 26223305 and on the fork is `0x` for all six, `isCoin(coin)` false. the comment entered at commit 747b91d (2026-10-17) for an earlier build.

structural fix: default to `head - 100` (as ci.yml does) and keep `FORK_BLOCK` as an optional cache pin; the RUNBOOK sentence "latest minus 100" already describes that.

### S-11  check-preflight.sh is dead tooling with stale expectations
severity: low. category: legibility. file: script/tools/check-preflight.sh:37-44, 63-65.

evidence: default block 26158000 (pre-stack, S-02); the comment "the two factory rows of DEPLOY step 3" while `owner_rows` holds one row; "the owner held 0.068 eth at that block"; the RUNBOOK no longer references the script (grep over docs/RUNBOOK.md and the workflows returns nothing).

structural fix: delete it or re-base it on head with the live expectation (no failed rows for mainnet.json besides the balance row).

## verified OK

- build identity: the seven masked runtime hashes (immutable and both link slots zeroed, link placeholders `__$<34 hex>$__` replaced before masking, the `ArtifactLoader.load` method) recomputed from `out/` equal `BUILD_HASH_*` in Checks.sol:74-91; both library creation hashes equal `BUILD_CREATION_HASH_*`. `_preBuild` makes these preflight rows, so a stale `out/` or an edited tree fails before anything is sent; test/BuildIdentity.t.sol reads the same constants (lines 117-123).
- CREATE2 determinism: salts `credits.core.v1`, `credits.controller.v1`, `credits.core.seaportAdapter.v1`, `credits.core.strategyAdapter.v1`, renderer `keccak(RENDERER_SALT, salt)`, libraries salt 0, all through `0x4e59b4…956C`. the Core address commits to the linked creation code (both library addresses substituted, PostflightChecks.sol:110-121) and every constructor argument including the artist and `address(0)` coin; `_ensureCore` reverts `AddressMismatch` if `new` lands elsewhere. the renderer address is a function of owner and salt only (Builder.sol:350-353), confirmed by the token config naming it before the Core exists and by the Core constructor computing `COIN` through `predictToken` (Core.sol:338-342).
- config hash: `keccak256(abi.encode(LaunchConfig))` covers every field including the two overrides and `image`/`description`; Deploy and Resume revert `ConfigHashMismatch`; the wrapper compares `CONFIG_HASH` with the preflight print when `SIGNOFF=1` and refuses an empty one in a real run (`late`).
- library linking: postflight finds both library addresses in the Core runtime (`PUSH20` scan plus tail hash), compares each with the compiled CREATE2 address, and `runtimeSlotsMatch` checks every link site (group 0 CoreLib, group 1 CoreOpsLib) and all nine immutable sites against the getters (PostflightChecks.sol:410-442). LAUNCH_ONLY compares the record's `library`/`opsLibrary` with the compiled addresses (deploy.sh:229-243; `cast compute-address` prints the bare address, checked). Etherscan verification passes both `--libraries` flags.
- live stack pins against the chain now (head 26223305): every code hash, `constantsHash`, `STACK_VERSION` 2, `deprecated()` true, `deployFee()` 0, `tokenDeployer` `0x99EB…0903`, `protocolRecipient` `0xbD5A…40df`, its `treasury` `0x41c3…A6A4` equals v2-mainnet.json, `teamFeeRecipient` the owner, owner code `0xef0100612373d7…` equals `OWNER_DELEGATION_CODE`, Calibur code hash equals `OWNER_DELEGATE_CODEHASH`, `keyCount()` 0, factory `owner()` `0xCB43…17F9`.
- decision 186/187 parameters: preflight pins skim 690, bounty 9000 (override only via the signed `overrides.bounty`), sniper 9000 / 1800, `settings.sniperSeconds == launch.sniperSeconds`, pool fee flag, ticks (lower = start, upper = highest usable), supply 1e27, `rateCap == 3 * rateStart`, rate in bounds, settings / sale / credit / quote bounds, payee set and not a stack address, artist required when a cut is nonzero, restricted with an empty allowlist, seaport recipients non-zero / unique / not system. postflight reads back skim and bounty from the hook `skimConfig`, the mev schedule (start, end = baseline, window, startTime = launchedAt), ticks mirrored on the locker position, restricted flag, admin, image, description, renderer, settings byte-equal, sale, credit, quote, payee, artist, the three deferred coin rows and the Core CREATE2 row (DEPLOYER is always set by the wrapper).
- stop points: all twelve transactions are idempotent by code or state presence (`_ensure*`, `_wire`, `_launch` on `coin.code.length == 0`); every intermediate state is recoverable by `RESUME=state`; `RESUME=replay` is bounded to `[FIRST, FIRST + COUNT]` and every nonce below the signer nonce must map to a landed saved hash (deploy.sh:289-302); `--slow` on every broadcast for the EIP 7702 account; `DEFER_LAUNCH` and `LAUNCH_ONLY` exclude each other and `RESUME=state`; LAUNCH_ONLY re-derives CORE and FROM_BLOCK from the record and checks Core code, controller, coin, both adapters, coin without code, factory deprecated and token deployer against the record before `launchOnlyChecks` repeats them on chain (test-launch-only-guards.sh covers six tampers and the dry run).
- second run: live env refuses while `deployments/1.json` exists without `RESUME`; on any env a full rerun fails `predicted core is empty` inside `Deploy.run` before the broadcast (the simulation reverts). wrong `CORE`: `Resume` reverts `CoreMismatch`; replay/record fail the postflight row `core: address is the CREATE2 address of the config and the deployer` and write no record. wrong `FROM_BLOCK`: after the creation block the wrapper dies "the Core already had code before block"; before it the bisection finds the creation block.
- DRY_RUN: no wallet read, no `cast wallet address`, git guards warn, every other guard collected, exit 1 on any; `RESUME` and `DRY_RUN` exclusive except through `LAUNCH_ONLY` (intended, tested). secrets: private key args and env refused, `ETH_*` unset, password file must be a file outside the tree, keystore by name only, the record never carries a live rpc url. anvil envs accept only 127.0.0.1/localhost; the send rpc's chain id is checked in a real run.
- dev scripts are honest about what is faked: `anvil --auto-impersonate` and `forge --unlocked` for the owner and seeded accounts, `anvil_setBalance` funding, `evm_increaseTime`/`evm_mine` warps, `anvil_setNextBlockBaseFeePerGas` 1 gwei before keeper ticks (e2e-real.sh:159), the Statements owner and the CreditStrategy impersonated in phase 6, real Credits moved from the strategy, real pool swaps, real keeper binary, Seaport orders signed by fresh keys. rehearse-signer.sh impersonates the real owner for exactly one `transferOwnership`, then signs everything with a throwaway keystore and the owner's 7702 code set by `anvil_setCode`. none of these touch mainnet; ports and chain ids are checked.
- freeze gate: `check-freeze.sh` reads STATUS section 4 (all `pending` today), so `script/deploy.sh mainnet` is refused by `gitguard` until the candidate is frozen; DRY_RUN reports it as a warning.

## stale comments and names

| file:line | text | should be |
|---|---|---|
| script/LaunchConfig.sol:18-24 | "the constantsHash() the master v2 stack reports", "runtime code hashes ... of the master v2 stack contracts ... v2-master.json holds ... these hashes" | the live stack of v2-mainnet.json at block 26205064 (verified, S-01) |
| script/Builder.sol:14, 22, 47 | "salt prefix of `CoinRenderer`", "the address of the `CoinRenderer`", "the renderer is the `CoinRenderer` of the config (decision 127)" | `LogoCoinRenderer` (decision 160); the salt string `credits.coinRenderer.v1` stays |
| script/SystemDeployer.sol:76 | "creates `CoinRenderer` at `rendererAddress(c)`" | `LogoCoinRenderer` |
| script/SystemDeployer.sol:56-57 | "the both linked libraries go first" | "both linked libraries go first" |
| script/PostflightV2.sol:220, 233 | "the coin's metadata renderer is the `CoinRenderer` of the config"; row name `coin: metadata renderer is the CoinRenderer of the config` | `LogoCoinRenderer` (the row name is matched by tests, change both) |
| script/Deploy.s.sol:9-10, script/Resume.s.sol:68-69 | `--private-key $KEY` example invocations | keystore (`--account`) only, S-09 |
| script/Checks.sol:626 | "(the master launch fee is 0)" | "(the live factory's fee is 0 at the pin)" |
| script/dev/e2e-real.sh:103-106 | "the live protocol occupies them at recent head blocks" | stale for this build, S-10 |
| script/dev/anvil.sh:3, :17; script/dev/local.sh:87; .env.example:4; README.md:46 | fork block 26158000 "the pin block" | a block at or after 26202473, S-02 |
| script/tools/check-preflight.sh:37-44 | "FORK_BLOCK (default 26158000)", "the two factory rows of DEPLOY step 3", "the owner held 0.068 eth" | S-11 |
| script/config/v2-master.json, docs/STATUS.md section 6 | "the stack is not yet on mainnet" | the stack is live since 26202473 |
| docs/RUNBOOK.md:32, 82 | "the coin renderer `CoinRenderer`", "(`CoinRenderer`, transactions 6 and 7 create and bind it)" | `LogoCoinRenderer`, transactions 7 and 8 of twelve |
| docs/RUNBOOK.md:28, 30, 81, 145 | `lockRecipients`, "the locked recipients row is a WARN until `lockRecipients`" | `coin.lock()` (decision 126; Lock.s.sol:310); the row is the info row `coin: lock` |
| docs/RUNBOOK.md:28 | "73 rows, every one ok" | the row count is not pinned anywhere; drop the number or pin it in a test |
| docs/RUNBOOK.md:86 | "`Settings` has 37 fields in five storage slots" | 39 fields (S-04) |
| docs/RUNBOOK.md:225, 258 | "an anvil fork of block 26158000", "CI can load it (ci.yml and candidate.yml start an anvil from it)" | S-01, S-02 |
| docs/SPEC.md:259 | "lowers `minProtocolSkimShareBps` to 1,000", "`lockRecipients` is a later owner decision" | S-07 |
| docs/SPEC.md:251, 298 | `lockRecipients` | `lock()` |
| script/SetSettings.s.sol:47 | 37 type `TUPLE` | 39 (S-04) |
| script/Checks.sol:232-236 | `else _warn(filledName, ...)` for `block.chainid != 1` | dead from deploy.sh (always `--chain-id 1`); keep for a bare `forge script` or remove |

exit vocabulary: no occurrence in script/** (grep); the only one is historical text in DECISIONS.md row 8.

## launch gates: proven versus assumed

proven by the scripts (a failing row or guard stops the run before a signature):
1. the compiled tree is the pinned build (seven masked runtime hashes, two creation hashes) and `forge build` succeeded.
2. the live v2 stack is byte-identical to the 26205064 pin (nine code hashes, constantsHash across five members, STACK_VERSION 2, treasury), the factory is deprecated, the owner is the config owner and the signer, hook/locker/mev enabled, token deployer set, deploy fee at most 0.1 ether, a stranger's `deployToken` reverts `Deprecated()`, the owner's `deployToken` with this exact config succeeds on a snapshot (and its gas is printed).
3. the owner account carries exactly the pinned 7702 delegation to the pinned Calibur code with an empty key registry.
4. the config: placeholders filled, rate bounds and the 3x cap, every settings/sale/credit/quote bound, supply, ticks, skim 690, bounty 9000 (or signed override), sniper 9000/1800 in both places, restricted with no extra entries, metadata rule, image/description byte caps, payee ppm bound, seaport recipients sane, owner/creator/payee not dead or stack, Credits and Statements supplies at least the pin.
5. the predicted Core, renderer and coin addresses are empty (first run) and the signoff hash equals the loaded config.
6. the signer is `DEPLOYER`, the config owner and the factory owner; `KEYSTORE_ACCOUNT`/`PASSWORD_FILE` set and outside the tree; `PRIVATE_RPC` present and on chain 1; `ETHERSCAN_API_KEY` present; clean tree on main with every freeze row ok; no existing record.
7. after the broadcast: every row of postflight (code, settings, libraries and immutables, controller, adapters, pool, hook, mev, locker, position, coin, allowlist, renderer, tokenURI, payee, artist, Core CREATE2 identity) and the record shape; LAUNCH_ONLY additionally the record-versus-chain and record-versus-build guards.

assumed (no script proves it):
1. the twelve-transaction gas total fits `DEPLOY_GAS_ESTIMATE` 22,000,000 and the deployer balance covers it at the launch day base fee plus priority fee (S-06; the rehearsal gate is pending).
2. the keystore named in the shell is the owner key (a dry run cannot prove it: `SIGNER=DEPLOYER` when `DRY_RUN=1`).
3. the geth/reth mempool policy for delegated accounts (one in-flight transaction, no nonce gaps) is handled by `--slow`; anvil does not emulate the policy, so the signer drill proves the sequencing, not the policy.
4. the pool's dynamic lp fee is 0 and the protocol leg lands at the factory's protocol recipient (S-05: warn and unread).
5. the read rpc `https://gateway.tenderly.co/public/mainnet` (mainnet.env) serves archive state for the block bisection and `cast code --block` during the launch (a public endpoint; no guard checks archive capability or rate limits).
6. in `RESUME=replay` and `RESUME=record` the preflight rows other than the three prediction rows still hold (S-03).
7. the artist address passes the Core's `_forbidden` list: preflight has no row; the Deploy simulation reverts `ForbiddenTarget` before anything is sent, so it is caught late but caught.
8. `rateStart` is the launch day market price of 100 points (decision 187 reserves this for deployment day sign off; the scripts only pin the 3x ratio).
