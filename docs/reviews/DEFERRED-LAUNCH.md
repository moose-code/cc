# deferred launch: who can take the predicted coin address

dated 2026-10-17. question: between `DEFER_LAUNCH=1 script/deploy.sh mainnet` and `LAUNCH_ONLY=1 script/deploy.sh mainnet`, can anyone but the factory owner create a coin at the address the Core holds as its `COIN` immutable?

answer: no.

source read: the verified source of the deployed factory `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`, Sourcify full match (https://sourcify.dev/server/v2/contract/1/0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c?fields=all). the two files are vendored unchanged in `docs/reviews/factory-source/`; line numbers below refer to them.

| file | sha256 |
|---|---|
| `ArtCoinsFactoryV2.sol` | `14135d0f107d80f1b233b2d6bcc781faa51c9804970bc536679bf6ec8771faa5` |
| `ArtCoinsDeployerV2.sol` | `22eaa7f832915c3e06067d802b52a911650ed997b48d812d9e483d154538deb6` |

mainnet today (read from https://ethereum-rpc.publicnode.com at block 26216576): `deprecated()` is true. state read on the fork: `deprecated()` is true, `owner()` is `0xCB43078C32423F5348Cab5885911C3B5faE217F9`, `pendingOwner()` is zero, `tokenDeployer()` is `0x99EB38d6a757a9f1061dFb1887bffD4637050903`.

## how the address is derived

| step | location | fact |
|---|---|---|
| salt | `ArtCoinsFactoryV2.sol` lines 170 to 171, 274 to 276 | the CREATE2 salt is `keccak256(abi.encode(msg.sender, configHash(c)))`. `predictToken(sender, c)` uses the same `_salt` (line 210) |
| create2 | `ArtCoinsDeployerV2.sol` lines 55 to 71 | the token deployer runs `create2` with that salt over init code that carries every constructor argument. the deployer address is part of the address |
| entry | `ArtCoinsFactoryV2.sol` lines 148 to 154 | `deployToken` reverts `Deprecated` unless `msg.sender` is the owner while `deprecated` is true |
| deployer entry | `ArtCoinsDeployerV2.sol` line 63 | `deploy` reverts `NotFactory` for every caller but the factory |

## what a third party can do

1. call `deployToken` while `deprecated` is true: reverts at line 154.
2. call `deployToken` after the owner sets `deprecated` to false (`setDeprecated`, line 646, owner only): the salt contains the caller's own address, so the same config lands at a different address. the predicted address needs the salt of the owner address.
3. call the token deployer directly: reverts at line 63.
4. send ETH or tokens to the predicted address: CREATE2 fails only when the address has code or a nonzero nonce. a balance leaves the launch unaffected.
5. change the inputs of the prediction: `setTokenDeployer` (line 634), `setDeprecated`, the hook, locker and mev module enables and the default allowlist are owner only. the owner key is the signer of the deploy, so the owner is the only party that can move the address.

## what changes the address

an owner action on the factory between the two steps. the owner key is the deployer key (`0xCB43…17F9`, `pendingOwner()` is zero), so that key is the only key that can move the address or create a coin at it. the owner settings that move the prediction or open the factory: `setTokenDeployer`, `setDeprecated`, `setHook`, `setLocker`, `setMevModule`, `setExtension`.

how step 2 detects it, before anything is sent:

- `deploy.sh` guards (collected under `DRY_RUN=1`): `deprecated()` is still true, and `tokenDeployer()` equals the `tokenDeployer` key that step 1 saved in the record.
- `launchOnlyChecks` in `Resume.s.sol` repeats both as `FactoryChanged("deprecated")` and `FactoryChanged("tokenDeployer")`, and adds `FactoryChanged("predicted coin")` when `predictToken(deployer, config)` no longer equals the Core's `COIN`.
- `SystemDeployer._launch` reverts `AddressMismatch("coin")` as the last row.

after a moved prediction the Core stays paired with the old address and a new Core is the recovery (docs/RUNBOOK.md section 5).

## result

a third party cannot take the address. the deployer key controls the window between the two steps. leave the owner settings above unchanged on the factory until the launch lands.
