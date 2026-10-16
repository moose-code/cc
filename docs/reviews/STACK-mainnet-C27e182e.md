# mainnet artcoins v2 stack identity (factory 0xC27e182e)

the owner reports the artcoins v2 stack at launcher commit `6d09948655468680efbd63b66c34547821605739` (master, the fixture
record `script/config/v2-master.json`) deployed to ethereum mainnet with factory
`0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`. this file records the on chain comparison of that factory and the stack
members it exposes against the tracked fork fixture.

## method

- mainnet reads over `https://ethereum-rpc.publicnode.com` at head block 26205064. the stack first holds code at block
  26204950.
- fixture reads over a throwaway anvil on port 8601: mainnet fork at block 26158000 (tenderly public gateway) with
  `script/config/stack-master-26158000.hex` loaded, chain id 31337, the fixture addresses of `script/config/v2-master.json`.
- a member with no address immutable is compared by raw `codehash`. a member with address immutables is compared by a
  byte diff of the two runtime codes: the two codes are the same length and differ only in 20 byte address slots, and
  each differing slot holds the matching stack address of its own deployment (fixture address in the fixture code, mainnet
  address in the mainnet code). this is the immutable mask the task calls for, done by locating the differing runs rather
  than by a precomputed offset table.
- the engine pins (`script/LaunchConfig.sol`): `V2_CONSTANTS_HASH`, `V2_CODEHASH_FACTORY`, `V2_CODEHASH_ESCROW`,
  `V2_CODEHASH_TOKEN_DEPLOYER`, `V2_CODEHASH_FEE_CONTROLLER`.

## result

| member | mainnet address | runtime size | comparison | result |
|---|---|---|---|---|
| factory | 0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c | 16,034 | raw codehash 0xc81a73b9...8e0c65 equals `V2_CODEHASH_FACTORY` and the fixture factory | match |
| pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | n/a | same canonical uniswap v4 pool manager as the config and the fixture; factory.poolManager() returns it | match |
| escrow | 0xb65816a3ce6c4dfd1dfa6d27832ed77781a65192 | 3,712 | raw codehash 0xeb557e5b...2b9975 equals `V2_CODEHASH_ESCROW` and the fixture escrow | match |
| token deployer | 0x99EB38d6a757a9f1061dFb1887bffD4637050903 | 13,878 | factory.tokenDeployer(); same length as the fixture token deployer, differs only at two 20 byte slots, each the member's own factory address | match, immutables masked |
| fee controller (protocolRecipient) | 0xbD5A853f556F17EAF692a4925371f5BFe3DD40df | 3,962 | factory.protocolRecipient(); same length as the fixture fee controller, differs only at four 20 byte slots, each the member's own escrow address | match, immutables masked |
| hook | unknown | - | not exposed by the factory; not recovered | blocked, see below |
| locker | unknown | - | not exposed by the factory; not recovered | blocked, see below |
| mev module | unknown | - | not exposed by the factory; not recovered | blocked, see below |
| extension allowlist | unknown | - | not exposed by the factory; not recovered | blocked, see below |
| burn router | unknown | - | not exposed by the factory; not recovered | blocked, see below |

factory state reads (all match the fixture and `script/config/mainnet.json`): owner
`0xCB43078C32423F5348Cab5885911C3B5faE217F9`, STACK_VERSION 2, constantsHash
`0x1b7deab81425bd850537efbb78d999939ab5fe16c424268886a5554d864e23d0` (equals `V2_CONSTANTS_HASH`), deprecated true,
deployFee 0, teamFeeRecipient `0xCB43078C32423F5348Cab5885911C3B5faE217F9`.

## discovery chain

the mainnet escrow address is read from the fee controller: the fee controller runtime code holds its escrow at four
immutable slots, so the mainnet fee controller code reveals the mainnet escrow `0xb65816a3...`. the mainnet escrow then
matches the fixture escrow byte for byte, confirming the member.

## what is verified

the mainnet factory, pool manager, escrow, token deployer and fee controller are the artcoins v2 stack of launcher commit
6d099486, identical to the tracked fork fixture with each contract's own stack addresses in its immutable slots. the
factory constants hash and version match the pins the engine already carries.

## what blocks the retarget

the hook, locker, mev module, extension allowlist and burn router addresses are needed to point the launch at this stack
and are not on chain reachable from the factory alone:

- the factory validates these members through the `enabledHooks`, `enabledLockers` and `enabledMevModules` mappings
  rather than returning their addresses. the fixture member addresses and the superseded v2-mainnet member addresses are
  all `enabled* == false` on this factory, so the mainnet stack uses its own member addresses.
- the engine's config carries hook, locker, escrow and mev module as inputs (`script/config/mainnet.json` stack,
  `script/config/v2-mainnet.json`); the preflight then checks each against the factory and the hook globals. writing them
  requires the addresses.
- the members hold no address immutable that names the others (the escrow is immutable free; the hook, locker, mev module
  and burn router were not reached from the factory, token deployer, fee controller or escrow).
- the stack deployed in one batch at block 26204950. the members emit no OwnershipTransferred or other log at
  construction, so a log scan of that block does not name them, and the public RPCs here do not serve `trace_block` for
  the batch's internal CREATEs.

the authoritative source is the launcher's mainnet deployment record at commit 6d099486 (the broadcast json or the
printed deployment addresses). with the hook, locker, mev module, allowlist and burn router addresses, each is confirmed
by the same code comparison (hook, locker, mev module and burn router carry address immutables; the allowlist is small
and likely immutable free) and the pins `V2_CODEHASH_HOOK`, `V2_CODEHASH_LOCKER`, `V2_CODEHASH_MEV_MODULE`,
`V2_CODEHASH_ALLOWLIST`, `V2_CODEHASH_BURN_ROUTER`.

until then the launch keeps pointing at the fork fixture (`STACK=master`, `script/config/v2-master.json`); no stack
address in `script/config/mainnet.json` or `script/config/v2-mainnet.json` is changed, and the engine pins are unchanged.
