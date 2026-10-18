# deferred launch: who can take the predicted coin address

dated 2026-10-17. question: between `DEFER_LAUNCH=1 script/deploy.sh mainnet` and `LAUNCH_ONLY=1 script/deploy.sh mainnet`, can anyone but the factory owner create a coin at the address the Core holds as its `COIN` immutable?

answer: no.

source read: the verified source of the deployed factory `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c` (Sourcify full match, path `src/v2/ArtCoinsFactoryV2.sol` and `src/v2/utils/ArtCoinsDeployerV2.sol`). state read on the fork: `deprecated()` is true, `owner()` is `0xCB43078C32423F5348Cab5885911C3B5faE217F9`, `pendingOwner()` is zero, `tokenDeployer()` is `0x99EB38d6a757a9f1061dFb1887bffD4637050903`.

## how the address is derived

| step | location | fact |
|---|---|---|
| salt | `ArtCoinsFactoryV2.sol` lines 170 to 171, 274 to 276 | the CREATE2 salt is `keccak256(abi.encode(msg.sender, configHash(c)))`. `predictToken(sender, c)` uses the same `_salt` (line 210) |
| create2 | `ArtCoinsDeployerV2.sol` lines 55 to 71 | the token deployer runs `create2` with that salt over init code that carries every constructor argument. the deployer address is part of the address |
| entry | `ArtCoinsFactoryV2.sol` lines 148 to 154 | `deployToken` reverts `Deprecated` unless `msg.sender` is the owner while `deprecated` is true |
| deployer entry | `ArtCoinsDeployerV2.sol` lines 63 | `deploy` reverts `NotFactory` for every caller but the factory |

## what a third party can do

1. call `deployToken` while `deprecated` is true: reverts at line 154.
2. call `deployToken` after the owner sets `deprecated` to false (`setDeprecated`, line 646, owner only): the salt contains the caller's own address, so the same config lands at a different address. the predicted address needs the salt of the owner address.
3. call the token deployer directly: reverts at line 63.
4. send ETH or tokens to the predicted address: CREATE2 fails only when the address has code or a nonzero nonce. a balance leaves the launch unaffected.
5. change the inputs of the prediction: `setTokenDeployer` (line 634), `setDeprecated`, the hook, locker and mev module enables and the default allowlist are owner only. the owner key is the signer of the deploy, so the owner is the only party that can move the address.

## what changes the address

an owner action on the factory between the two steps. effects:

- `LAUNCH_ONLY` runs `resumeChecks` and `launchOnlyChecks` (Core address, no coin code, every earlier step on chain) and `preflightResume` (the stack and factory rows). `forge script` simulates the launch before it broadcasts, and a moved prediction reverts that simulation with `AddressMismatch("coin")`, so nothing is sent.
- `SystemDeployer._launch` reverts `AddressMismatch("coin")` when the coin lands elsewhere. a moved prediction leaves the Core permanently paired with an address that no longer matches the factory, and a new Core is the recovery (docs/RUNBOOK.md section 5).

the deferred postflight rows `deferred: coin equals the factory prediction for the deployer` and `deferred: coin salt is unused on the factory` hold at the end of the first step.

## result

a third party cannot take the address. the owner key controls the window between the two steps. keep `setTokenDeployer`, `setDeprecated`, `setHook`, `setLocker`, `setMevModule`, `setExtension` unused on the factory until the launch lands.
