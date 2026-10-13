// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {LaunchConfig} from "../script/LaunchConfig.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/ArtCoinsV2.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {Mainnet, Settings} from "../src/interfaces/Interfaces.sol";
import {TestSwapRouter} from "./utils/TestSwapRouter.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// independent review of the artcoins port. `test_POC_*` prove a finding on the pinned fork, `test_held_*` are
/// attacks that failed. every number quoted in REVIEW-port.md (git history before packet 0) comes from a log line in this file.
/// a plain receive only bounty recipient, which the hook's `streamForward` probe survives
contract Sink {
    receive() external payable {}
}

/// swaps once in the real pool from inside the eth callback of a core payout, so the hook pushes the fees into the core
/// while the core is in the middle of a door
contract SwapOnReceive {
    TestSwapRouter public immutable router;
    PoolKey internal key;
    uint256 public swapEth;
    bool public fired;

    constructor(TestSwapRouter router_, PoolKey memory key_) {
        router = router_;
        key = key_;
    }

    function arm(uint256 eth) external {
        swapEth = eth;
        fired = false;
    }

    function sell(ICore c, uint256[] calldata ids) external {
        c.sellForEth(ids);
    }

    function buyback(ICore c) external {
        c.buyback();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (swapEth != 0 && !fired) {
            fired = true;
            router.swap{value: swapEth}(key, true, -int256(swapEth), address(this));
        }
    }
}

contract ReviewPort is Fixture {
    using stdStorage for StdStorage;

    address internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = _user("attacker");
    }

    // ------------------------------------------------------------------ helpers

    function _forceBuyback(uint256 eth) internal {
        vm.deal(address(core), address(core).balance + eth);
        uint256 slot = stdstore.target(address(core)).sig("ethToBuyback()").find();
        vm.store(address(core), bytes32(slot), bytes32(core.ethToBuyback() + eth));
    }

    function _stockPool() internal {
        _skipSniperWindow();
        _buyCoin(_user("trader"), 20 ether);
    }

    // ------------------------------------------------------------------ P-1 open pool spoofs fee income (gone on v2)

    /// on v1 anyone could open a second pool on the live hook naming the core as bounty recipient, and the hook's push
    /// was booked as fee income. on v2 only a launcher (the factory) can open a pool on the hook, so nobody else can
    /// make it push eth to the core
    function test_FIXED_v2HookRefusesAPoolFromAStranger() public {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(coin)), 0x800000, 60, IHooks(lc.stack.hook));
        vm.prank(attacker);
        vm.expectRevert();
        PM.initialize(k, 79228162514264337593543950336);
        // eth from the hook itself is accepted and counted by the next book
        vm.deal(lc.stack.hook, 1 ether);
        vm.prank(lc.stack.hook);
        (bool ok,) = address(core).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(core.ethPot(), 0, "a hook push waits for the next book");
    }

    // ------------------------------------------------------------------ held: sandwich and jit liquidity on the 1 eth slice

    function _burnOneSlice() internal returns (uint256 burned) {
        vm.roll(block.number + 30);
        uint256 supply = coin.totalSupply();
        vm.prank(keeper);
        core.buyback();
        burned = supply - coin.totalSupply();
    }

    function _sandwich(uint256 x) internal returns (int256 pnl, uint256 burnedAttacked, uint256 potGain) {
        vm.deal(attacker, x);
        vm.prank(attacker);
        router.swap{value: x}(launchKey, true, -int256(x), attacker);
        uint256 coinGot = coin.balanceOf(attacker);
        uint256 pot0 = core.ethPot();
        burnedAttacked = _burnOneSlice();
        potGain = core.ethPot() - pot0;
        uint256 out = _sellCoin(attacker, coinGot);
        pnl = int256(out) - int256(x);
    }

    function test_held_sandwichLosesToTheSkim() public {
        _stockPool();
        _forceBuyback(1 ether);
        uint256 snap = vm.snapshotState();
        uint256 base = _burnOneSlice();
        emit log_named_uint("coin burned by one slice, no attacker", base);
        vm.revertToState(snap);
        uint256[3] memory xs = [uint256(5 ether), 20 ether, 100 ether];
        for (uint256 i; i < 3; ++i) {
            snap = vm.snapshotState();
            (int256 pnl, uint256 burned, uint256 gain) = _sandwich(xs[i]);
            emit log_named_uint("front run eth", xs[i]);
            emit log_named_int("attacker net eth", pnl);
            emit log_named_uint("coin burned for the core", burned);
            emit log_named_uint("pot gain during buyback", gain);
            assertLt(pnl, 0, "sandwich loses");
            vm.revertToState(snap);
        }
    }

    function _spot() internal view returns (uint256 coinPerEthWad, int24 tick) {
        (uint160 sqrtP, int24 t,,) = StateLibrary.getSlot0(PM, launchKey.toId());
        coinPerEthWad = FullMath.mulDiv(FullMath.mulDiv(sqrtP, sqrtP, 1 << 64), 1e18, 1 << 128);
        tick = t;
    }

    /// v2 decision: the coin is restricted, so a stranger cannot put the coin into the pool as liquidity at all (the pool
    /// manager is not a holder it may pay). the just in time position that v1 had to price (the burn never got less
    /// coin for the slice) cannot be built, and the slice buys what it bought before
    function test_held_jitLiquidityCannotBeBuiltOnARestrictedCoin() public {
        _stockPool();
        _forceBuyback(1 ether);
        uint256 snap = vm.snapshotState();
        uint256 base = _burnOneSlice();
        vm.revertToState(snap);

        (, int24 tick) = _spot();
        int24 lo = (tick / 200) * 200 - 400;
        int24 hi = lo + 1200;
        TestLiquidityHelper lp = new TestLiquidityHelper();
        vm.deal(attacker, 1000 ether);
        deal(address(coin), attacker, 2e27);
        vm.startPrank(attacker);
        coin.approve(address(lp), type(uint256).max);
        vm.expectRevert();
        lp.modify{value: 500 ether}(launchKey, lo, hi, 4e24);
        vm.stopPrank();
        assertEq(_burnOneSlice(), base, "the slice buys the same coin with the attempt made");
    }

    // ------------------------------------------------------------------ P-5 forbidden adapters

    /// regression for P-5: permit2, the v4 position manager and the universal router cannot become adapters
    function test_FIXED_permit2AndRoutersAreForbiddenAdapters() public {
        address[3] memory banned = [Mainnet.PERMIT2, Mainnet.POSITION_MANAGER, Mainnet.UNIVERSAL_ROUTER];
        for (uint256 i; i < banned.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(ICore.ForbiddenTarget.selector);
            core.addAdapter(banned[i]);
            assertFalse(core.allowedAdapter(banned[i]));
        }
    }

    // ------------------------------------------------------------------ P-4 launch hijack of the predicted coin (gone on v2)

    /// on v1 the coin address did not depend on the sender, so with an open factory anyone could copy the config, take
    /// the predicted address and bind the core to a pool that never pays it. on v2 `predictToken(sender, config)` folds
    /// the sender into the salt: a copy launched by another account lands elsewhere, and the real launch still lands on
    /// the address the core was built against. while the factory is deprecated a stranger cannot launch at all
    function test_FIXED_launchHijackCannotTakeThePredictedCoin() public {
        bytes32 salt = keccak256("hijack victim");
        address coreAt = vm.computeCreateAddress(owner, vm.getNonce(owner) + 1);
        LaunchConfig memory l = lc;
        l.name = "Victim";
        l.symbol = "VIC";
        l.salt = salt;
        vm.startPrank(owner);
        ICore core2 = Prod.newCore(
            owner,
            buildConfig(l, owner, address(0)),
            owner,
            address(Prod.newController(coreAt, lc.sale)),
            lc.payee,
            lc.stack,
            lc.rateStart,
            lc.settings
        );
        vm.stopPrank();
        assertEq(address(core2), coreAt);
        address coinAt = core2.COIN();
        assertEq(coinAt, predictCoin(l, owner, coreAt), "the Core computed the factory prediction");

        IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg = buildConfig(l, owner, coreAt);
        uint256 fee = FACTORY.deployFee();
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        FACTORY.deployToken{value: fee}(cfg);

        // the factory opens: the copy by the attacker lands on its own address
        vm.prank(owner);
        FACTORY.setDeprecated(false);
        vm.prank(attacker);
        address stolen = FACTORY.deployToken{value: fee}(cfg);
        assertTrue(stolen != coinAt, "the sender is part of the address");

        // and the real launch still gets the predicted address
        vm.prank(owner);
        assertEq(FACTORY.deployTokenAsOwner{value: fee}(cfg, lc.protocolBps), coinAt);
        assertEq(core2.COIN(), coinAt);
    }

    // ------------------------------------------------------------------ held: hook push inside the core's own payouts

    function _assertClean(string memory what) internal view {
        assertEq(address(core).balance, _tracked(), what);
    }

    /// a swap fired from the eth callback of a sell payout and the payment to the caller of the coin buyback. the
    /// hook pushes into `receive()` mid door, it is booked in full, and the books stay exact
    function test_held_swapInsidePayoutCallbacks() public {
        _stockPool();
        SwapOnReceive actor = new SwapOnReceive(router, launchKey);
        vm.deal(address(actor), 50 ether);
        _fundPot(2 ether);
        _assertClean("start");

        uint256[] memory ids = _credits(address(actor), 80);
        vm.warp(block.timestamp + 40 hours);
        actor.arm(1 ether);
        uint256 pot0 = core.ethPot();
        actor.sell(core, _slice(ids, 0, 3));
        assertTrue(actor.fired(), "swap fired inside the payout");
        core.book();
        assertGt(core.ethPot(), pot0 - 1 ether, "bounty booked");
        _assertClean("after sell");

        // the payment to the caller of the coin buyback is paid to the caller, who swaps from inside it
        _forceBuyback(1 ether);
        vm.roll(block.number + 30);
        actor.arm(1 ether);
        uint256 potB = core.ethPot();
        uint256 payBefore = address(actor).balance;
        actor.buyback(core);
        assertTrue(actor.fired(), "swap fired inside the caller payment");
        assertGt(address(actor).balance + 1 ether, payBefore, "the payment was paid");
        core.book();
        assertGt(core.ethPot(), potB, "bounty booked");
        _assertClean("after buyback payment");
    }

    function _slice(uint256[] memory a, uint256 from, uint256 n) internal pure returns (uint256[] memory r) {
        r = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = a[from + i];
        }
    }
}
