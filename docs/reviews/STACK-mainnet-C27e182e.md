# mainnet artcoins v2 stack identity (factory 0xC27e182e)

the owner reports the artcoins v2 stack at launcher commit `6d09948655468680efbd63b66c34547821605739` (master, the fixture
record `script/config/v2-master.json`) deployed to ethereum mainnet with factory
`0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`. this file records the on chain comparison of that factory and every stack
member against the tracked fork fixture.

## method

- mainnet reads over `https://ethereum-rpc.publicnode.com` and an archive RPC (`https://eth.drpc.org`) at head block
  26205064. the factory was created at block 26202473; the owner enabled the hook, locker and mev module at blocks
  26202492, 26202494 and 26202495.
- fixture reads over a throwaway anvil on port 8601: mainnet fork at block 26158000 with
  `script/config/stack-master-26158000.hex` loaded, chain id 31337, the fixture addresses of `script/config/v2-master.json`.
- a member with no address immutable is compared by raw `codehash`. a member with address immutables is compared by a
  byte diff of the two runtime codes: same length, differing only in 20 byte address slots, each holding the matching
  stack address of its own deployment.
- member addresses the factory does not expose are recovered from the owner's own `setHook`, `setLocker` and
  `setMevModule` calls to the factory (`trace_filter`), the fee controller's escrow immutable, and the hook's
  `globals()`. the factory, token deployer and fee controller addresses come from factory getters.

## recovered mainnet addresses

| member | mainnet address | source |
|---|---|---|
| factory | 0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c | given |
| pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | factory.poolManager() |
| hook | 0x866f31562dDE70d7b989C2529A9DEfFfFd3bE8cc | owner setHook(hook, true) at block 26202492 |
| locker | 0xbd049e961a414caF3Ec040405FA688f641e63C64 | owner setLocker(locker, true) at block 26202494 |
| mev module | 0x32aB8ec09EE09a37a6cD58FBC7d6dA2dA31982C5 | owner setMevModule(module, true) at block 26202495 |
| escrow | 0xb65816a3ce6c4dfd1dfa6d27832ed77781a65192 | fee controller escrow immutable and hook globals |
| extension allowlist | 0xc73eb3d8b3c0066dacBB3ed3a64658a5e54452b9 | hook globals |
| token deployer | 0x99EB38d6a757a9f1061dFb1887bffD4637050903 | factory.tokenDeployer() |
| fee controller (protocolRecipient) | 0xbD5A853f556F17EAF692a4925371f5BFe3DD40df | factory.protocolRecipient() |

## code comparison against the fixture

| member | runtime size | comparison | result |
|---|---|---|---|
| factory | 16,034 | raw codehash 0xc81a73b9...8e0c65 equals `V2_CODEHASH_FACTORY` and the fixture factory | match |
| pool manager | n/a | same canonical pool manager as the config and the fixture | match |
| escrow | 3,712 | raw codehash 0xeb557e5b...2b9975 equals `V2_CODEHASH_ESCROW` and the fixture escrow | match |
| locker | 8,274 | byte for byte equal to the fixture locker | match |
| mev module | 2,193 | same length as the fixture mev module, differs only at two 20 byte slots, each the member's own hook address | match, immutables masked |
| token deployer | 13,878 | same length as the fixture token deployer, differs only at two 20 byte slots, each the member's own factory address | match, immutables masked |
| fee controller | 3,962 | same length as the fixture fee controller, differs only at four 20 byte slots, each the member's own escrow address | match, immutables masked |
| hook | 17,369 | the fixture hook is 17,341; the mainnet hook is 28 bytes longer. the divergence starts at code offset 2,059 and is a shift of the code (a jump destination operand moves by exactly 28), not an immutable slot and not trailing metadata | mismatch, +28 bytes |

factory state reads (all match the fixture and `script/config/mainnet.json`): owner
`0xCB43078C32423F5348Cab5885911C3B5faE217F9`, STACK_VERSION 2, constantsHash
`0x1b7deab81425bd850537efbb78d999939ab5fe16c424268886a5554d864e23d0` (equals `V2_CONSTANTS_HASH`), deprecated true,
deployFee 0. hook reads: poolManager canonical, constantsHash equals `V2_CONSTANTS_HASH`, isLauncher(factory) true,
globals.feeEscrow is the escrow above, permission low bits 0xe8cc equal the fixture hook's.

## the hook mismatch

every stack member except the hook is identical to the fixture (commit 6d099486), with each member's own stack addresses
in its immutable slots. the hook differs: the mainnet hook holds 28 more bytes of code than the fixture hook, starting
at offset 2,059. the hook shares the constants hash, the stack version, the pool manager, the escrow, the launcher set
and the permission bits with the fixture hook, so it is a hook of the same stack; its code is a different build.

the hook is the skim and mev contract and the engine pins its code hash (`V2_CODEHASH_HOOK` in `script/LaunchConfig.sol`,
the fixture hook's hash). writing the mainnet hook into the launch config and repinning its hash to the mainnet value
would bless a hook whose bytecode this review did not reconcile to the fixture source. the owner decides: either the
mainnet hook is the intended launch build (a hook patched after the fixture snapshot, in which case the engine repins to
it and the other members, and the fork gates run against a recent mainnet fork where the stack exists), or the fixture is
the intended build (in which case the mainnet hook is not the launch target).

## state of the repoint

the launch keeps pointing at the fork fixture (`STACK=master`, `script/config/v2-master.json`); no stack address in
`script/config/mainnet.json` or `script/config/v2-mainnet.json` is changed and the engine pins are unchanged, pending the
owner's decision on the hook. with that decision the repoint is: mainnet.json stack factory, hook, locker, escrow and mev
module to the addresses above (pool manager, tick spacing and pool fee are unchanged), v2-mainnet.json to the full set,
and the `V2_CODEHASH_*` and `V2_PIN_BLOCK` pins to the mainnet stack at block 26202473 or later.

## resolution: the deployed stack is the launch stack

the owner decided the deployed stack is the launch stack. the hook matches artcoins commit `d27c932f` (tag
`v2-stack-2026-10-15`, `FOUNDRY_PROFILE=ci`: solc 0.8.26, viaIR, runs 200, no metadata). its only source difference from
the fixture build (`6d099486`) is in `HookCalldata.sol`: the referrer parse bounds are tighter (the inner slice must be at
least 0x60 bytes and the payload length word must fit). fee skim, bounty, protocol share, escrow depositors, lock,
lowerBaselineSkim and permission bits are unchanged.

the engine's buyback hookData (abi encoded SwapData with the refund address) is unaffected: a malformed referrer slice
yields a zero referrer, and referral is off.

repoint: `script/config/mainnet.json` stack and `script/config/v2-mainnet.json` carry the addresses above (`v2-master.json`
stays as the fixture record). `V2_CODEHASH_HOOK`, `V2_CODEHASH_MEV_MODULE`, `V2_CODEHASH_TOKEN_DEPLOYER` and
`V2_CODEHASH_FEE_CONTROLLER` are repinned to the plain `extcodehash` of the deployed contracts (the pin includes
immutables, so the three members whose immutables differ change too). factory, locker, escrow, allowlist and burn router
hashes equal the existing pins. the burn router is `0x183751c6D50c3f2B377c0aD9BD8Fab1e187740d4`.
