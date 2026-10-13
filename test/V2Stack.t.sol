// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {
    IArtCoinsFactoryV2 as F,
    IArtCoinsHookV2,
    IArtCoinsTokenV2,
    IArtCoinsLpLockerV2,
    IArtCoinsFeeEscrowV2
} from "../src/interfaces/ArtCoinsV2.sol";
import {V2Stack, IV2Reads} from "./utils/V2Stack.sol";
import {V2_CONSTANTS_HASH} from "../script/LaunchConfig.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";

/// bounty recipient with an empty receive: the hook's 2300 gas push succeeds
contract EmptyRecipient {
    receive() external payable {}
}

/// bounty recipient that writes storage in receive: the 2300 gas push fails and the hook credits the escrow
contract WritingRecipient {
    uint256 public hits;

    receive() external payable {
        hits += 1;
    }
}

/// @notice the live artcoins v2 stack on the pinned fork, with a restricted coin launched, traded and drained through
/// the real hook, locker and escrow. gas is logged, run with -vv
contract V2StackTest is Test {
    error TransferRestricted(address from, address to, uint256 amount);

    V2Stack.Params internal p;
    V2Stack.Stack internal s;
    address internal owner;
    address internal creator;
    address internal buyer;
    TestSwapRouter internal swapper;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        s = V2Stack.attach();
        owner = s.owner;
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        vm.deal(owner, 10 ether);
        vm.deal(buyer, 100 ether);
        swapper = new TestSwapRouter();
        p = V2Stack.mainnetParams(owner);
    }

    /// a launch on the v2 factory at the mainnet factory minimums: bounty 9000 (the 1000 minimum protocol skim share
    /// leaves 9000), lp fee 3000 pips, baseline skim 1000 bps (10 points), sniper 9000 bps falling to 1000 over 30
    /// minutes, restricted, protocol slot at the factory default 2000
    function _config(address bountyRecipient, bytes32 salt) internal view returns (F.DeploymentConfigV2 memory c) {
        c.token = F.TokenConfigV2({
            tokenAdmin: owner,
            name: "Flow",
            symbol: "FLOW",
            salt: salt,
            image: "ipfs://image",
            description: "{}",
            totalSupply: 1e27,
            renderer: address(0)
        });
        c.pool = F.PoolConfigV2({
            hook: s.hook,
            tickIfToken0IsCoin: -175000,
            tickSpacing: 200,
            extension: address(0),
            extensionData: ""
        });
        c.fee = F.FeeConfigV2({
            lpFeePips: 3000,
            baselineSkimBps: 1000,
            bountyBps: 9000,
            maxReferralBpsOfVolume: 0,
            bountyRecipient: payable(bountyRecipient)
        });
        address[] memory rr = new address[](1);
        rr[0] = creator;
        uint16[] memory rb = new uint16[](1);
        rb[0] = 8000;
        int24[] memory lo = new int24[](1);
        lo[0] = -175000;
        int24[] memory hi = new int24[](1);
        hi[0] = 887200;
        uint16[] memory pb = new uint16[](1);
        pb[0] = 10000;
        c.locker = F.LockerConfigV2({
            locker: s.locker,
            rewardRecipients: rr,
            rewardBps: rb,
            tickLower: lo,
            tickUpper: hi,
            positionBps: pb
        });
        c.mev = F.MevConfigV2({module: s.mev, startingSkimBps: 9000, windowSeconds: 1800});
        c.restriction = F.RestrictionConfigV2({restricted: true, allowed: new address[](0)});
    }

    function _launch(address bountyRecipient, bytes32 salt) internal returns (address coin, PoolKey memory key) {
        F.DeploymentConfigV2 memory c = _config(bountyRecipient, salt);
        address predicted = F(s.factory).predictToken(owner, c);
        // the factory stays deprecated: the owner may launch anyway
        vm.prank(owner);
        uint256 g = gasleft();
        coin = F(s.factory).deployTokenAsOwner{value: p.deployFee}(c, p.protocolBps);
        console.log("launch gas", g - gasleft());
        assertEq(coin, predicted, "predictToken");
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: Mainnet.POOL_FEE,
            tickSpacing: Mainnet.TICK_SPACING,
            hooks: IHooks(s.hook)
        });
    }

    function _buy(PoolKey memory key, uint256 ethIn) internal {
        vm.prank(buyer);
        swapper.swap{value: ethIn}(key, true, -int256(ethIn), buyer);
    }

    // the live stack of the fork is the stack the preflight pins describe
    function test_liveStackPassesCheck() public view {
        V2Stack.check(s, p); // the DeployV2Lib post deploy requires, on the live stack
        assertEq(IV2Reads(s.hook).constantsHash(), V2_CONSTANTS_HASH);
        assertEq(F(s.factory).STACK_VERSION(), 2);
        assertEq(F(s.factory).owner(), owner);
        assertTrue(F(s.factory).deprecated());
        assertEq(F(s.factory).deployFee(), V2Stack.MAINNET_DEPLOY_FEE);
        assertEq(uint160(s.hook) & 0x3FFF, V2Stack.HOOK_LOW_BITS);
    }

    // a bounty recipient with an empty receive is paid at once by the hook, on a buy of a restricted coin
    function test_launchRestrictedCoinWithEmptyRecipient() public {
        EmptyRecipient r = new EmptyRecipient();
        (address coin, PoolKey memory key) = _launch(address(r), bytes32(uint256(1)));
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        assertTrue(F(s.factory).isCoin(coin));
        assertTrue(t.restricted(), "restricted");
        assertEq(t.admin(), owner);
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.canonicalHook(), s.hook);
        assertEq(IArtCoinsHookV2(s.hook).skimConfig(t.canonicalPoolId()).bountyRecipient, address(r));
        assertEq(IArtCoinsHookV2(s.hook).skimConfig(t.canonicalPoolId()).bountyBps, 9000);
        assertEq(IArtCoinsHookV2(s.hook).skimConfig(t.canonicalPoolId()).lpFeePips, 3000);
        // the engine, router and swapper are not on the allowlist, the locker and escrow are seeded and pinned
        assertFalse(t.isAllowed(address(swapper)));
        assertTrue(t.isAllowed(s.locker) && t.isPinned(s.locker));
        assertTrue(t.isAllowed(s.escrow) && t.isPinned(s.escrow));

        // buy and sell through PoolManager.unlock, the bounty lands on the empty receive recipient at once
        uint256 before = address(r).balance;
        _buy(key, 1 ether);
        uint256 bounty = address(r).balance - before;
        assertGt(bounty, 0, "bounty pushed");
        assertEq(IArtCoinsFeeEscrowV2(s.escrow).balances(address(r), address(0)), 0, "nothing escrowed");
        uint256 got = t.balanceOf(buyer);
        assertGt(got, 0, "bought");
        console.log("bounty on a 1 eth buy", bounty);
    }

    // a bounty recipient whose receive writes storage fails the stipend push: the hook credits the escrow, anyone claims
    function test_writingRecipientIsCreditedInEscrowAndClaims() public {
        WritingRecipient r = new WritingRecipient();
        (, PoolKey memory key) = _launch(address(r), bytes32(uint256(2)));
        IArtCoinsFeeEscrowV2 e = IArtCoinsFeeEscrowV2(s.escrow);
        uint256 before = address(r).balance; // a test address can already hold dust on the fork
        _buy(key, 1 ether);
        assertEq(address(r).balance, before, "stipend push failed");
        assertEq(r.hits(), 0);
        uint256 credit = e.balances(address(r), address(0));
        assertGt(credit, 0, "credited in escrow");
        e.claim(address(r), address(0)); // anyone, all gas forwarded
        assertEq(address(r).balance, before + credit, "claim delivered");
        assertEq(r.hits(), 1);
        assertEq(e.balances(address(r), address(0)), 0);
    }

}
