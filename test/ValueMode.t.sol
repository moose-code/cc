// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings, Quote, CreditSale, RATE_SCORE, POINT_UNIT} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {QuoteController} from "./attackers/QuoteController.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";

/// the value switch (decisions 148, 150 to 154): the controller's rate limited reference of the balance token, its
/// protected buy and sale prices, `valuePerPoint`, and the Core in value mode: the eth bid is the shared balance instance
/// times the protected buy value per point. ETH fills drop the shared instance; flat balance fills leave it alone.
/// Unusable quotes close ETH and balance payouts. Sale references exclude cost;
/// final quotes still cover the Core's historical cost floor.
abstract contract ValueBase is Fixture {
    /// wei per balance token base unit is 0.49, so one point (`POINT_UNIT * UNIT` base units) is worth 4.9e13 wei, the
    /// opening eth rate of 4.9e15 per 100 points: `2^96 / sqrt(0.49)`
    uint160 internal constant SP = uint160(FixedPoint96.Q96 * 10 / 7);
    /// full range liquidity the test provides to the real native eth / balance token pool. above `minLiquidity` (1e18),
    /// so the quote reads the pool, and deep enough that a `_swapSpot` move lands near its target sqrt
    uint128 internal constant POOL_LIQ = 1e20;
    /// full range for tick spacing 60 (a multiple of 60)
    int24 internal constant TICK_FULL = 887_220;
    PoolKey internal key;
    TestLiquidityHelper internal lp;

    function setUp() public virtual override {
        super.setUp();
        _enterPhase2();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(key, SP);
        lp = new TestLiquidityHelper();
        xt.mint(address(this), 1e24);
        xt.approve(address(lp), type(uint256).max);
        xt.approve(address(router), type(uint256).max);
        _addFullRange(int256(uint256(POOL_LIQ)));
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k, _spotOf(SP));
        // tol 450 and step 500 satisfy the loop closure bound at the credit spread 1,000 and the product bound at the
        // margin 1,000 (decisions 153 and 157): a round trip through the reference band loses
        _setQuote(Quote({referenceRateBpsPerHour: 1_000, referenceStepBps: 500, tolBps: 450, referenceMaxStale: 1 days, referenceMinSeconds: 0, minLiquidity: 1e18}));
        mod.setAvailable(1e30);
    }

    using StateLibrary for IPoolManager;

    /// adds `liq` of full range liquidity to the real pool through the pool manager. the test contract pays both legs:
    /// eth sent along (leftover refunded) and the balance token it approved. a positive `liq` adds, a negative removes
    function _addFullRange(int256 liq) internal {
        vm.deal(address(this), address(this).balance + 2_000 ether);
        lp.modify{value: 2_000 ether}(key, -TICK_FULL, TICK_FULL, liq);
    }

    /// the pool's live liquidity at the current tick
    function _liquidityNow() internal view returns (uint128) {
        return PM.getLiquidity(key.toId());
    }

    /// moves the pool spot by `bps` with a real swap (positive raises the spot, negative lowers it) and returns the new
    /// spot. a swap to the target sqrt price limit lands the spot at the target within tick rounding: buying the balance
    /// token with eth lowers the sqrt price and raises the spot, selling it does the reverse
    function _swapSpot(int256 bps) internal returns (uint256 newSpot) {
        (uint256 start, bool ok) = ctl.spotPrice();
        require(ok, "spot unreadable");
        if (bps == 0) return start;
        uint256 target =
            bps > 0 ? start * (10_000 + uint256(bps)) / 10_000 : start * (10_000 - uint256(-bps)) / 10_000;
        return _swapToSpot(target);
    }

    /// swaps the real pool until its spot reaches `target` wei per 1e18 base units, stopping at the target sqrt price
    /// limit within tick rounding. returns the new spot
    function _swapToSpot(uint256 target) internal returns (uint256 newSpot) {
        (uint256 start,) = ctl.spotPrice();
        uint160 limit = _sqrtOf(target);
        if (target > start) {
            vm.deal(address(this), address(this).balance + 2_000 ether);
            router.swapWithLimit{value: 2_000 ether}(key, true, -int256(2_000 ether), limit, address(this), "");
        } else if (target < start) {
            router.swapWithLimit(key, false, -int256(1e24), limit, address(this), "");
        }
        (newSpot,) = ctl.spotPrice();
    }

    /// the spot of sqrt price `sp`, wei per 1e18 base units
    function _spotOf(uint160 sp) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(1e18, FixedPoint96.Q96, sp), FixedPoint96.Q96, sp);
    }

    /// the sqrt price of a spot `p` wei per 1e18 base units, by the inverse of `_spotOf` within its rounding
    function _sqrtOf(uint256 p) internal pure returns (uint160) {
        // sp = 2^96 * sqrt(1e18 / p)
        return uint160(FullMath.mulDiv(FixedPoint96.Q96, _sqrt(1e36 / p), 1e9));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _setQuote(Quote memory q) internal {
        vm.prank(owner);
        ctl.setQuote(q);
    }

    function _valueOn() internal {
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.balanceBidCapBps = 11_000;
        s.saleFloorBps = 5_000;
        // value mode requires the eth spend cap active (under 10,000, decision 157); 9,999 keeps it effectively open
        s.spendCapBps = 9_999;
        _setSettings(s);
        // the switch turns on age only eligibility (decision 155). the credit spread stays at the fixture's 1,000: the
        // value mode spread of 200 (decision 153) does not close the loop at tol 450, so the switch config keeps a
        // spread that satisfies the loop closure bound (decision 157)
        vm.startPrank(owner);
        ctl.setAgeEligibilityOn(true);
        vm.stopPrank();
    }

    /// the eth bid the value mode prices for 100 points at the shared rate `bps`: `bps * valuePerPoint(false) * 100 / 10_000`
    function _valueRate(uint256 bps) internal view returns (uint256) {
        (uint256 v,) = ctl.valuePerPoint(false);
        return bps * v * 100 / 10_000;
    }
}

contract ValueReferenceTest is ValueBase {
    using stdStorage for StdStorage;

    // promise: decision 176 a paid refresh preserves earned funded climb before its payment empties the buying room
    function test_paidRefreshPreservesEarnedClimbBeforePotFalls() public {
        Settings memory s = core.settings();
        s.reserveWei = 0.1 ether;
        s.callerFee = 0.01 ether;
        s.callerMaxBaseFee = 0;
        _setSettings(s);
        vm.prank(owner);
        core.setRate(0.0049 ether);
        uint256 oldPot = core.ethPot();
        stdstore.target(address(core)).sig("ethPot()").checked_write(0.11 ether);
        vm.deal(address(core), address(core).balance - oldPot + 0.11 ether);
        _warp(4 minutes);
        uint256 earned = core.ethPrice();
        assertGt(earned, 0.0049 ether, "four funded minutes earned a climb");

        vm.roll(block.number + 1);
        core.refreshReference();
        assertEq(core.ethPot(), 0.1 ether, "the refresh payment left only the reserve");
        assertEq(core.rateAtCheckpoint(), earned, "the checkpoint kept the earned climb");
        _warp(6 hours);
        assertEq(core.ethPrice(), earned, "the empty pot did not fund later climb");
    }

    // promise: SPEC 8 setBalancePoolKey starts the reference at the spot, in the owner's transaction
    function test_referenceStartsAtTheSpot() public view {
        assertEq(ctl.referencePrice(), _spotOf(SP));
        assertEq(ctl.referenceTime(), block.timestamp);
    }

    // promise: setting the same pool key again with the live spot resets the reference and the sample ring to that spot
    function test_resettingTheSameKeyReseedsTheReference() public {
        uint256 ref0 = ctl.referencePrice();
        uint256 moved = _swapSpot(3_000);
        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        assertGt(ctl.referencePrice(), ref0, "the reference drifted up");
        assertLt(ctl.referencePrice(), moved, "and trails the spot");
        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + 1);
        (uint256 live,) = ctl.spotPrice();
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k, live);
        assertEq(ctl.referencePrice(), live, "the reference equals the live spot");
        assertEq(ctl.referenceTime(), block.timestamp, "the sample time is now");
        // the ring holds the live spot twice, so the buy price is the spot itself
        (uint256 v, bool ok) = ctl.valuePerPoint(false);
        assertTrue(ok, "the quote reads the reseeded ring");
        assertEq(v, FullMath.mulDiv(POINT_UNIT * _moduleUnit(), live, 1e18), "the buy price is the live spot");
        // the ring and the refresh block hold the live values (slots 9 to 12 of the controller storage layout)
        assertEq(uint256(vm.load(address(ctl), bytes32(uint256(9)))), live, "spotSampleA");
        assertEq(uint256(vm.load(address(ctl), bytes32(uint256(10)))), live, "spotSampleB");
        uint256 liqs = uint256(vm.load(address(ctl), bytes32(uint256(11))));
        assertEq(uint128(liqs), _liquidityNow(), "liqSampleA");
        assertEq(uint128(liqs >> 128), _liquidityNow(), "liqSampleB");
        assertEq(uint48(uint256(vm.load(address(ctl), bytes32(uint256(12))))), uint48(block.number), "lastRefreshBlock");
        // a refresh in the same block is refused, so the seed block is the last sample
        assertFalse(ctl.refreshReference(), "no refresh in the seed block");
        // one block later the quote still reads the reseeded ring
        vm.roll(block.number + 1);
        (uint256 v2, bool ok2) = ctl.valuePerPoint(false);
        assertTrue(ok2, "the quote reads the ring one block later");
        assertEq(v2, v, "the same buy price one block later");
        // a stale expected spot is refused by the 4.5 percent guard
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("spot")));
        ctl.setBalancePoolKey(k, live * 2);
    }

    // promise: SPEC 8 an update moves the reference toward the spot by at most referenceRateBpsPerHour times the elapsed time
    function test_observeMovesAtMostTheRate() public {
        uint256 ref0 = ctl.referencePrice();
        _swapSpot(10_000); // a real swap pushes the spot to about double the reference, past the step cap
        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1); // the refresh runs at most once per block, so a new block is needed past the seed
        ctl.refreshReference();
        assertEq(ctl.referencePrice(), ref0 * 10_500 / 10_000, "half an hour at 1,000 bps an hour moves the 5 percent step");
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        assertEq(ctl.referencePrice(), ref0 * 10_500 / 10_000 * 10_500 / 10_000, "a full hour moves one more 5 percent step");
    }

    // promise: SPEC 8 a long idle gains one step, the referenceStepBps bound
    function test_longIdleGainsOneStep() public {
        uint256 ref0 = ctl.referencePrice();
        _swapSpot(-5_000); // a real swap pushes the spot to about half the reference, past the step cap
        vm.warp(block.timestamp + 20 hours);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        assertEq(ctl.referencePrice(), ref0 * 9_500 / 10_000, "twenty idle hours move one step of 5 percent");
    }

    // promise: SPEC 8 repeated updates gain nothing beyond the rate: a block by block spam over an hour stays within the
    // compounded rate of one update over the same hour
    function test_spamGainsNothingBeyondTheRate() public {
        uint256 ref0 = ctl.referencePrice();
        _swapSpot(10_000);
        uint256 snap = vm.snapshotState();
        // half an hour of 12 second spam: rate 1,000 bps an hour reaches the 500 bps step over the window
        for (uint256 i; i < 150; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            ctl.refreshReference();
            ctl.refreshReference(); // a second call in the same second moves nothing
        }
        uint256 spammed = ctl.referencePrice();
        vm.revertToState(snap);
        vm.warp(block.timestamp + 1_800);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        uint256 once = ctl.referencePrice();
        assertEq(once, ref0 * 10_500 / 10_000, "one update after half an hour moves the 5 percent step");
        // 150 steps of 3.33 bps compound to at most e^(0.05) of the reference, just above one 5 percent step
        assertLe(spammed, ref0 * 10_525 / 10_000, "the spam stays within the compounded rate");
    }

    // promise: a rate too small for a one bps move over the call interval still tracks: the sample time advances only by
    // the seconds that produced the integer move, so the reference is not pinned when the per call move floors to zero
    function test_slowRateStillTracksUnderFrequentCalls() public {
        _setQuote(
            Quote({
                referenceRateBpsPerHour: 100,
                referenceStepBps: 500,
                tolBps: 450,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 0,
                minLiquidity: 1e18
            })
        );
        uint256 ref0 = ctl.referencePrice();
        _swapSpot(10_000); // the spot is pushed to about double, so the move is always rate limited upward
        // a call every 12 seconds: 100 bps an hour over 12 seconds is 0.33 bps, which floors to a zero integer move
        for (uint256 i; i < 300; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
        uint256 ref = ctl.referencePrice();
        assertGt(ref, ref0, "the reference tracks despite each call flooring its move to zero");
        // one hour at 100 bps an hour is about one percent, compounded in one bps steps
        assertApproxEqRel(ref, ref0 * 10_100 / 10_000, 1e15, "an hour of 12 second calls moves about one percent");
    }

    // promise: SPEC 8 a refresh runs only when the last sample is older than referenceMinSeconds; a call before then is a
    // no op, so the keeper pays once per cadence and the sale doors do not resample every block
    function test_refreshGatedByReferenceMinSeconds() public {
        _setQuote(
            Quote({
                referenceRateBpsPerHour: 1_000,
                referenceStepBps: 500,
                tolBps: 450,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 600,
                minLiquidity: 1e18
            })
        );
        uint256 ref0 = ctl.referencePrice();
        _swapSpot(10_000);
        vm.warp(block.timestamp + 599);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        assertEq(ctl.referencePrice(), ref0, "no refresh before the cadence elapses");
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        assertGt(ctl.referencePrice(), ref0, "the refresh runs once the cadence has elapsed");
    }

    // promise: SPEC 8 the protected prices clamp the band to the spot sampled at the last refresh (a prior block): buys
    // off min(sampledSpot, ref + tol), sales off max(sampledSpot, ref - tol) (decision 159, C01)
    function test_protectedPricesAtSpotAboveAndBelow() public {
        uint256 ref0 = ctl.referencePrice();
        uint256 unitPoint = POINT_UNIT * UNIT;
        // push the spot far above, refresh in a new block to sample it, then read in the next block so the quote uses
        // that sample (not the seed held in the previous slot)
        _swapToSpot(ref0 * 2);
        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.roll(block.number + 1);
        uint256 refHi = ctl.referencePrice();
        (uint256 spotHi,) = ctl.spotPrice();
        assertGt(spotHi, refHi * 10_450 / 10_000, "the sampled spot sits above the reference plus the band");
        (uint256 buyHi,) = ctl.valuePerPoint(false);
        (uint256 sellHi,) = ctl.valuePerPoint(true);
        assertEq(buyHi, FullMath.mulDiv(unitPoint, refHi * 10_450 / 10_000, 1e18), "a sampled high spot buys at the reference plus the band");
        assertEq(sellHi, FullMath.mulDivRoundingUp(unitPoint, spotHi, 1e18), "and sells at the sampled spot");
        // push the spot far below, sample it, read in the next block
        _swapToSpot(refHi / 4);
        vm.warp(block.timestamp + 30 minutes);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        vm.roll(block.number + 1);
        uint256 refLo = ctl.referencePrice();
        (uint256 spotLo,) = ctl.spotPrice();
        assertLt(spotLo, refLo * 9_550 / 10_000, "the sampled spot sits below the reference less the band");
        (uint256 buyLo,) = ctl.valuePerPoint(false);
        (uint256 sellLo,) = ctl.valuePerPoint(true);
        assertEq(buyLo, FullMath.mulDiv(unitPoint, spotLo, 1e18), "a sampled low spot buys at the sampled spot");
        assertEq(sellLo, FullMath.mulDivRoundingUp(unitPoint, refLo * 9_550 / 10_000, 1e18), "and sells at the reference less the band");
        assertLt(buyLo, sellLo, "the buy value stays under the sale value");
    }

    // promise: SPEC 8 the quote is unusable beyond referenceMaxStale, under minLiquidity, with no module unit, or with referenceMaxStale 0
    function test_unusableStates() public {
        (, bool ok) = ctl.valuePerPoint(false);
        assertTrue(ok, "fresh and deep");
        vm.warp(block.timestamp + 1 days + 1);
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "stale beyond referenceMaxStale");
        vm.roll(block.number + 1);
        ctl.refreshReference();
        (, ok) = ctl.valuePerPoint(false);
        assertTrue(ok, "an update refreshes it");
        // raise the required liquidity above the pool's sampled liquidity: the quote reads the liquidity sampled at the
        // last refresh, so a threshold above the standing depth makes it unusable
        _setQuote(Quote({referenceRateBpsPerHour: 1_000, referenceStepBps: 500, tolBps: 450, referenceMaxStale: 1 days, referenceMinSeconds: 0, minLiquidity: uint128(POOL_LIQ) * 2}));
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "liquidity under the minimum");
        _setQuote(Quote({referenceRateBpsPerHour: 1_000, referenceStepBps: 500, tolBps: 450, referenceMaxStale: 1 days, referenceMinSeconds: 0, minLiquidity: 1e18}));
        mod.setRevertUnit(true);
        (, ok) = ctl.valuePerPoint(true);
        assertFalse(ok, "a failing unit read");
        mod.setRevertUnit(false);
        _setQuote(Quote({referenceRateBpsPerHour: 0, referenceStepBps: 0, tolBps: 450, referenceMaxStale: 0, referenceMinSeconds: 0, minLiquidity: 1e18}));
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "referenceMaxStale 0, the launch placeholder, keeps it unusable");
    }

    // promise: INTEGRATION BadSetting on setQuote (field bounds, the all or nothing reference triple, the loop closure
    // and the reference band) and OnlyOwner. the fixture credit spread is 1,000 and the Core bid margin 1,000
    function test_setQuoteBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("referenceStepBps")));
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1, referenceStepBps: 10_001, tolBps: 0, referenceMaxStale: 1, referenceMinSeconds: 0, minLiquidity: 0}));
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("tolBps")));
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1, referenceStepBps: 10_000, tolBps: 10_000, referenceMaxStale: 1, referenceMinSeconds: 0, minLiquidity: 0}));
        // a partial reference triple (step 0 while the rate and staleness are set) is a misconfiguration
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("referenceTriple")));
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1, referenceStepBps: 0, tolBps: 450, referenceMaxStale: 1, referenceMinSeconds: 0, minLiquidity: 0}));
        // tol 500 needs a credit spread of at least 1,053, above the fixture's 1,000: the loop would not close
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("creditSpreadBps")));
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1, referenceStepBps: 1, tolBps: 500, referenceMaxStale: 1, referenceMinSeconds: 0, minLiquidity: 0}));
        // step 700 at tol 450 widens the reference band past the bid margin
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("referenceBand")));
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1, referenceStepBps: 700, tolBps: 450, referenceMaxStale: 1, referenceMinSeconds: 0, minLiquidity: 0}));
        // a valid quote: the reference triple set, tol 450 inside the loop closure and the band
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1_200, referenceStepBps: 500, tolBps: 450, referenceMaxStale: 3_600, referenceMinSeconds: 600, minLiquidity: 1e18}));
        vm.stopPrank();
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setQuote(Quote({referenceRateBpsPerHour: 1_200, referenceStepBps: 500, tolBps: 450, referenceMaxStale: 3_600, referenceMinSeconds: 600, minLiquidity: 1e18}));
    }

    // promise: SPEC 11 a seed manipulated between signing and landing reverts: setBalancePoolKey refuses a live spot
    // more than 4.5 percent from the owner's expected spot, regardless of quote tolerance
    function test_poolKeySeedRevertsOnManipulation() public {
        uint256 expected = _spotOf(SP);
        _swapToSpot(expected * 2); // a real swap doubles the spot, far beyond the 4.5 percent band
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("spot")));
        ctl.setBalancePoolKey(k, expected);
    }

    // promise: the pool-key seed keeps its 4.5 percent transaction guard when the trading tolerance is zero
    function test_poolKeySeedAllowsNormalDriftWithZeroTradingTolerance() public {
        _setQuote(Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 0,
            referenceMaxStale: 3_600,
            referenceMinSeconds: 600,
            minLiquidity: 1e18
        }));
        uint256 expected = _spotOf(SP);
        uint256 spot = _swapSpot(100);
        assertGt(spot, expected);
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k, expected);
        assertEq(ctl.referencePrice(), spot);
        uint256 pushed = _swapToSpot(expected * 10_500 / 10_000);
        assertGt(pushed, expected * 10_450 / 10_000, "the live spot crosses the independent seed guard");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("spot")));
        ctl.setBalancePoolKey(k, expected);
    }
}

contract ValueModeTest is ValueBase {
    using stdStorage for StdStorage;
    // promise: an owner pause freezes the shared value-mode climb through booking, funding and half-life edits
    function test_pauseFreezesSharedBidAndResumesEarnedClimb() public {
        _valueOn();
        vm.warp(block.timestamp + 2 minutes);
        uint256 earned = core.sharedRate();
        vm.prank(owner);
        core.setPaused(true);
        vm.warp(block.timestamp + 6 hours);
        vm.deal(address(this), 1 ether);
        core.fund{value: 1 ether}();
        core.book();
        Settings memory s = core.settings();
        s.peakHalfLife += 1 hours;
        _setSettings(s);
        assertEq(core.sharedRate(), earned, "paused booking cannot lift the shared bid");
        vm.prank(owner);
        core.setPaused(false);
        assertEq(core.sharedRate(), earned, "earned climb survives the pause");
        vm.warp(block.timestamp + 2 minutes);
        assertGt(core.sharedRate(), earned, "shared climb resumes");
    }

    // promise: SPEC 4 the launch keeps value mode off and the quote placeholders unusable
    function test_launchValues() public view {
        Settings memory s = core.settings();
        assertFalse(s.valueModeOn, "value mode off at launch");
        assertEq(lc.quote.tolBps, 100, "the launch band");
        assertEq(lc.quote.referenceMaxStale, 0, "referenceMaxStale an owner input, unusable until set");
    }

    // promise: SPEC 4 the switch resets the shared instance to its floor and prices the eth bid off it
    function test_switchResetsTheSharedInstanceAndPricesTheBid() public {
        _fundPot(20 ether);
        _warp(2 hours);
        _valueOn();
        assertEq(core.balanceRate(), 9_000, "the switch opens the shared instance at the floor");
        assertEq(core.ethRate(), _valueRate(9_000), "the eth bid is the shared rate times the value per point");
        assertEq(core.ethPrice(), _valueRate(9_000));
        uint256[] memory ids = _credits(seller, 1);
        assertEq(core.bidOf(ids[0]), core.ethRate() * _scoreOf(ids[0]) / RATE_SCORE, "per credit by score");
    }

    // promise: SPEC 4 an eth fill drops the shared instance and a balance fill leaves it: the balance route pays the
    // posted price and never reads the instance (decision 164); the posted rate never moves
    function test_ethFillsDropTheInstanceAndBalanceFillsDoNot() public {
        _valueOn();
        _fundPot(20 ether);
        _warp(30 minutes);
        uint256 e0 = core.ethPrice();
        uint256 posted = core.balanceRate();
        uint256[] memory ids = _credits(seller, 2);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        uint256 e1 = core.ethPrice();
        assertLt(e1, e0, "an eth fill drops the shared instance");
        assertEq(core.balanceRate(), posted, "the posted balance rate does not move on an eth fill");
        vm.prank(seller);
        core.sellForBalance(_one(ids[1]));
        assertEq(core.ethPrice(), e1, "a balance fill leaves the shared instance");
        assertEq(core.balanceRate(), posted, "nor does it move the posted rate");
    }

    // promise: SPEC 4 in value mode the shared instance climbs with the balance bid off and with no usable module, and
    // only the switch resets it: a settings edit, a module set and the bid turning on leave it (decision 164)
    function test_onlyTheSwitchResets() public {
        Settings memory s = core.settings();
        s.balanceBidOn = false;
        _setSettings(s);
        _valueOn();
        _warp(30 minutes);
        uint256 climbed = core.ethPrice();
        assertGt(climbed, _valueRate(9_000), "the shared instance climbs in value mode with the balance bid off");
        s = core.settings();
        s.climbPerMinBps = 50;
        s.recoveryClimbPerMinBps = 50;
        _setSettings(s);
        assertEq(core.ethPrice(), climbed, "a settings edit does not reset it");
        _setBalanceModule(address(mod));
        assertEq(core.ethPrice(), climbed, "a module set does not reset it");
        s = core.settings();
        s.balanceBidOn = true;
        _setSettings(s);
        assertEq(core.ethPrice(), climbed, "the bid turning on does not reset it");
        assertEq(core.balanceRate(), 9_000, "the posted balance rate throughout");
    }

    // promise: a stale value quote closes acquisitions while fee booking and age-only redemption stay live
    function test_staleQuoteClosesAcquisitions() public {
        Composed memory c = _composeOnce();
        _valueOn();
        _fundPot(20 ether);
        vm.warp(block.timestamp + 1 days + 1); // the reference is stale
        assertEq(core.ethRate(), 0, "the eth bid closes when the quote is stale");
        assertEq(core.ethPrice(), 0, "the unclamped value rate closes too");
        uint256[] memory ids = _credits(seller, 2);
        uint256 before = seller.balance;
        vm.prank(seller);
        vm.expectRevert(ICore.PotTooSmall.selector);
        core.sellForEth(_one(ids[0]));
        assertEq(seller.balance, before, "a stale quote spends no ETH");
        vm.prank(seller);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        core.sellForBalance(_one(ids[1]));
        core.book();
        core.redeemStatement(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), address(mod), "conversion runs by age, no quote read");
    }

    // promise: a stale value quote cannot book donated Credits at a 1 wei basis, and composition preserves their costs
    function test_staleQuoteAdoptKeepsLastGoodBasisThroughComposition() public {
        _valueOn();
        _fundPot(1 ether);
        core.book();
        uint256 lastGood = core.rateAtCheckpoint();
        assertEq(lastGood, core.ethPrice(), "a usable quote established the accounting rate");
        uint256[] memory ids = _credits(seller, 80);
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(seller);
            CREDITS.transferFrom(seller, address(core), ids[i]);
        }
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(core.ethRate(), 0, "the stale quote still closes ETH acquisition");
        assertEq(core.ethPrice(), 0, "the live value price does not fall back");
        vm.prank(seller);
        core.adopt(ids);
        uint256 sum;
        for (uint256 i; i < ids.length; ++i) {
            uint256 pay = lastGood * _scoreOf(ids[i]) / RATE_SCORE;
            uint256 expected = pay + pay * core.settings().buyToArtistBps / 10_000;
            (, uint256 cost,) = core.creditInfo(ids[i]);
            assertEq(cost, expected, "adoption uses the stored accounting rate");
            assertGt(cost, 1, "the quote outage cannot erase cost");
            sum += cost;
        }
        uint256 sid = STATEMENTS.supply() + 1;
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        (bool held, uint256 statementCost,) = core.statementInfo(sid);
        assertTrue(held, "the page composed");
        assertEq(statementCost, sum, "composition preserves every adopted cost");
    }

    // promise: adoption refuses a missing accounting rate while a value quote is unusable
    function test_staleQuoteAdoptWithoutStoredBasisReverts() public {
        _valueOn();
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        vm.warp(block.timestamp + 1 days + 1);
        stdstore.target(address(core)).sig("rateAtCheckpoint()").checked_write(uint256(0));
        assertEq(core.ethPrice(), 0, "the quote is stale");
        vm.expectRevert(ICore.NoQuote.selector);
        core.adopt(ids);
        assertEq(core.pileSize(), 0, "a failed adoption leaves the pile unchanged");
    }

    // promise: a hostile value quote cannot lift the ETH bid above rateCap; an unusable quote closes acquisitions
    function test_hostileQuoteIsBounded() public {
        _valueOn();
        _fundPot(20 ether);
        QuoteController q = new QuoteController(address(core), address(ctl));
        _setController(address(q));
        q.setValue(type(uint256).max, true);
        assertEq(core.ethRate(), core.settings().rateCap, "a huge quote pays the rate cap");
        uint256 bal0 = core.balanceRate();
        q.setValue(0, true);
        assertEq(core.ethRate(), 0, "a zero quote closes the ETH bid");
        q.setValue(1e13, false);
        assertEq(core.ethRate(), 0, "a not-ok quote closes the ETH bid");
        assertEq(core.balanceRate(), bal0, "the quote never moves the balance bid");
        uint256[] memory ids = _credits(seller, 1);
        assertEq(core.balanceBidOf(ids[0]), 0, "missing clamp disables the quoted BALANCE bid");
        assertEq(core.balanceBidForScore(_scoreOf(ids[0])), 0, "score quote shares the failed clamp");
        vm.prank(seller);
        vm.expectRevert(ICore.ZeroAmount.selector);
        core.sellForBalance(ids);
        assertEq(CREDITS.ownerOf(ids[0]), seller, "failed clamp did not take the Credit");
    }

    // promise: outside value mode a controller without balanceClampFor cannot silence the flat BALANCE bid
    function test_missingClampKeepsModeOffBalanceBid() public {
        QuoteController q = new QuoteController(address(core), address(ctl));
        _setController(address(q));
        uint256[] memory ids = _credits(seller, 1);
        uint256 bid = core.balanceBidOf(ids[0]);
        assertGt(bid, 0, "the posted bid is available outside value mode");
        uint256 before = xt.balanceOf(seller);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(seller) - before, bid, "the seller receives the posted payout");
    }

    // promise: a hostile clamp cannot raise the posted payout or turn a failed quote into a BALANCE fill
    function test_hostileClampCannotRaiseThePostedPayout() public {
        _valueOn();
        QuoteController q = new QuoteController(address(core), address(ctl));
        _setController(address(q));
        uint256[] memory ids = _credits(seller, 1);
        bytes memory request = abi.encodeWithSelector(IControllerV1.balanceClampFor.selector);
        vm.mockCall(address(q), request, abi.encode(type(uint256).max, true));
        uint256 posted = _scoreOf(ids[0]) * UNIT * (10_000 - core.settings().balanceDiscountBps) / 10_000;
        assertEq(core.balanceBidOf(ids[0]), posted, "oversized clamp is limited to the posted bid");
        vm.clearMockedCalls();
        vm.mockCall(address(q), request, abi.encode(type(uint256).max, false));
        assertEq(core.balanceBidOf(ids[0]), 0, "false status refuses the BALANCE bid");
        vm.clearMockedCalls();
        vm.mockCall(address(q), request, hex"1234");
        assertEq(core.balanceBidOf(ids[0]), 0, "short answer refuses the BALANCE bid");
        assertEq(CREDITS.ownerOf(ids[0]), seller, "the Credit remains with the seller");
    }

    // promise: SPEC 8 in value mode a credit's floor is valueOf(score) times floorMultBps with the cost dropped, and a
    // buy at that floor sold back into the eth bid at its hard cap loses at least the spread
    function test_valueFloorClosesTheRoundTrip() public {
        uint256 id = _fillEthPile(1)[0];
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        ctl.refreshReference();
        uint256 score = _scoreOf(id);
        (uint256 vSell,) = ctl.valuePerPoint(true);
        (uint256 spot,) = ctl.spotPrice();
        uint256 floor = ctl.referencePrice() * 9_550 / 10_000;
        assertEq(ctl.valueOf(score), FullMath.mulDivRoundingUp(score * UNIT, spot > floor ? spot : floor, 1e18), "valueOf is the protected sale value");
        uint256 price = ctl.creditPrice(id);
        assertEq(price, ctl.valueOf(score) * ctl.floorMultBps() / 10_000, "the floor drops the cost term");
        assertEq(ctl.floorMultBps(), 12_100, "the spread of 1,000 over the hard cap of 11,000");
        // the most the eth bid pays for this credit: the shared instance at the hard cap times the buy value
        (uint256 vBuy,) = ctl.valuePerPoint(false);
        uint256 mostPaid = 11_000 * vBuy * score / POINT_UNIT / 10_000;
        assertGe(price, mostPaid * 10_200 / 10_000, "the floor clears the bid's ceiling by the spread");
        assertLe(vBuy, vSell, "the buy value is under the sale value");
    }

    /// a buyer of the engine's credits that sells each one straight back
    address internal constant TRIPPER = address(0x7419);

    /// buys pile credit `id` at its sale price through `buyCredit` after a `refreshReference()`, then in the next second sells
    /// it back through the eth door or the balance door. `back` is the eth received, or the balance token received
    /// valued at the pool spot
    function _trip(uint256 id, bool viaBalance) internal returns (uint256 paid, uint256 back) {
        ctl.refreshReference();
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        paid = price * 2 - TRIPPER.balance;
        _nextSecond();
        _tripBack(id, viaBalance);
        uint256 got = xt.balanceOf(TRIPPER);
        back = viaBalance ? got * _spotNow() / 1e18 : TRIPPER.balance - (price * 2 - paid);
        if (got != 0) {
            vm.prank(TRIPPER);
            xt.transfer(address(0xdead), got);
        }
    }

    function tripBackExternal(uint256 id) external {
        _tripBack(id, true);
    }

    function _tripBack(uint256 id, bool viaBalance) internal {
        vm.startPrank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        if (viaBalance) core.sellForBalance(_one(id));
        else core.sellForEth(_one(id));
        vm.stopPrank();
    }

    function _spotNow() internal view returns (uint256 spot) {
        (spot,) = ctl.spotPrice();
    }

    /// a round trip loses at least the spread: what comes back is at most the price paid over (10_000 + spreadBps),
    /// within one wei of the price's rounding. at the hard cap the bound is exact, so the floored price can sit one wei
    /// under the spread over the bid's most
    function _assertLoses(uint256 paid, uint256 back, string memory state) internal view {
        assertGt(back, 0, state);
        uint256 m = 10_000 + ctl.creditSpreadBps();
        assertLe(back * m, (paid + 1) * 10_000, state);
    }

    // promise: SPEC 10 round trips in both currencies at the floor, at the cap after a climb, in the next block, after
    // 20 idle minutes, across a currency switch, at spot above and below the reference and with the reference stale: a
    // credit bought from the engine and sold straight back loses at least the spread
    function test_roundTripsLoseTheSpread() public {
        uint256[] memory ids = _fillEthPile(16);
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
        uint256 k;
        (uint256 paid, uint256 back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth at the floor");
        (paid, back) = _trip(ids[k++], true);
        _assertLoses(paid, back, "balance at the floor, across a currency switch");
        (paid, back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth in the next block, across a currency switch");
        _warp(20 minutes);
        (paid, back) = _trip(ids[k++], true);
        _assertLoses(paid, back, "balance after 20 idle minutes");
        _warp(20 minutes);
        (paid, back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth after 20 idle minutes");
        _warp(6 hours);
        assertEq(core.sharedRate(), 11_000, "the shared instance climbed to the cap");
        (paid, back) = _trip(ids[k++], false);
        _assertLoses(paid, back, "eth at the cap");
        _warp(6 hours);
        (paid, back) = _trip(ids[k++], true);
        _assertLoses(paid, back, "balance at the cap");
        // the spot pushed up and down against the reference with real swaps; the reference settles to the moved spot so
        // a round trip at that settled reference loses the spread (the buy and the sell read the same sampled spot)
        uint256 ref = ctl.referencePrice();
        uint256[2] memory moved = [ref * 3 / 2, ref * 6 / 10];
        for (uint256 i; i < 2; ++i) {
            _swapToSpot(moved[i]);
            _settleReference();
            (paid, back) = _trip(ids[k++], false);
            _assertLoses(paid, back, i == 0 ? "eth at spot above the reference" : "eth at spot below the reference");
            (paid, back) = _trip(ids[k++], true);
            _assertLoses(paid, back, i == 0 ? "balance at spot above the reference" : "balance at spot below the reference");
        }
        // the reference stale after the buy: both bids close until a usable quote returns
        _swapToSpot(ctl.referencePrice());
        _settleReference();
        uint256 id = ids[k++];
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price}(id);
        _warp(1 days + 1);
        assertEq(core.ethRate(), 0, "the stale quote closes the ETH bid");
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        this.tripBackExternal(id);
    }

    // promise: a real pool move can leave the prior-block Credit ask below a later ETH bid after the production lock
    function test_persistentRealPoolRiseCanOutrunTheAskAfterReturnLock() public {
        uint256[] memory ids = _fillEthPile(1);
        _valueOn();
        _setCreditSaleOn(true);
        _setReturnLock(6 hours);
        _setQuote(Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 100,
            referenceMaxStale: 1 days,
            referenceMinSeconds: 600,
            minLiquidity: 1e18
        }));
        CreditSale memory sale = _creditSale();
        sale.spreadBps = 203;
        vm.prank(owner);
        ctl.setCredit(sale);
        _warp(ctl.creditWindow());
        vm.roll(block.number + 1);
        _fundPot(50 ether);

        // The pool swap executes through the real v4 manager with test-funded ETH. The Credit buyer pays only the
        // Credit ask, so a positive Credit round trip here is not a net swap, gas or MEV profit calculation.
        uint256 beforeSpot = _spotNow();
        uint256 movedSpot = _swapSpot(3_000);
        assertGt(movedSpot, beforeSpot * 12 / 10, "the real pool move did not reach the test band");
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(TRIPPER, price);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price}(ids[0]);
        vm.prank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        vm.expectPartialRevert(ICore.ReturnLocked.selector);
        vm.prank(TRIPPER);
        core.sellForEth(_one(ids[0]));

        for (uint256 i; i < 36; ++i) {
            _warp(10 minutes);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
        uint256 beforeEth = TRIPPER.balance;
        vm.prank(TRIPPER);
        core.sellForEth(_one(ids[0]));
        uint256 back = TRIPPER.balance - beforeEth;
        emit log_named_uint("real swap spot wei per balance token", movedSpot);
        emit log_named_uint("credit purchase wei", price);
        emit log_named_uint("credit resale wei after six-hour lock", back);
        assertGt(back, price, "the later bid did not outrun the stale ask");
    }

    /// refreshes the reference, a step and a block at a time, until it is within 0.1 percent of the pool spot, so a round
    /// trip runs at a settled reference where the buy and the sell read the same sampled spot
    function _settleReference() internal {
        for (uint256 i; i < 60; ++i) {
            (uint256 spot,) = ctl.spotPrice();
            uint256 ref = ctl.referencePrice();
            uint256 diff = spot > ref ? spot - ref : ref - spot;
            if (diff <= ref / 1_000) break;
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
    }

    // promise: SPEC 10 a balance round trip loses the spread even when the live pool spot leads the reference
    // in value mode the balance payout is lowered to the controller's `balanceClampFor`: the eth bid for the score
    // valued in tokens at the protected sale price per token (`max(prior-block spot, reference - tol)`), so a filled
    // payout is worth at most the eth bid when the engine sells the tokens (decision 165). without the clamp a credit
    // bought off the reference-protected ask and sold straight into the balance bid returned tokens realizable at the
    // live spot, gaining the spot over reference gap the spread does not cover. shrunk from the InvariantsValue
    // invariant_v20 counterexample (CI run 39046569753): spot 1.9108e18, reference 0.5145e18 (3.55x), credit bought for
    // 0.025119 eth, par payout 0.030983 xt realizable at the spot for 0.059202 eth, net +0.034083. the clamp caps the
    // payout at 0.01666 eth over pSell 1.9108, worth the eth bid at spot, so the round trip loses.
    function test_balanceRoundTripLosesWhenSpotLeadsReference() public {
        uint256[] memory ids = _fillEthPile(4);
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
        // push the pool spot to 3.55x the reference and leave the reference unsettled: one refresh per block moves it at
        // most one step, so the ask stays priced off the lagging reference while the spot leads it
        _swapToSpot(ctl.referencePrice() * 355 / 100);
        // let the prior-block sample catch the pushed spot (the sale price the engine realizes tokens at) while the
        // reference walks up one step a block and stays well below it: the spot leads the reference
        for (uint256 i; i < 3; ++i) {
            _nextSecond();
            ctl.refreshReference();
        }
        _nextSecond();
        (uint256 paid, uint256 back) = _trip(ids[0], true);
        _assertLoses(paid, back, "balance with the spot far above the reference");
    }

    // promise: an unusable value reference pays no balance tokens, and a transfer cannot bypass the return lock
    function test_balanceFillRefusesWhileTheReferenceIsUnusable() public {
        uint256[] memory ids = _fillEthPile(4);
        _valueOn();
        _setReturnLock(21_600);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
        ctl.refreshReference();
        uint256 id = ids[0];
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        address second = address(0xB0B2);
        uint256 score = _scoreOf(id);
        (uint256 healthy, bool ok) = ctl.balanceClampFor(score, type(uint128).max);
        assertTrue(ok);
        assertGt(healthy, 0, "healthy cap");
        // drain the pool and take two samples
        _addFullRange(-int256(uint256(POOL_LIQ)));
        for (uint256 i; i < 2; ++i) {
            _nextSecond();
            ctl.refreshReference();
        }
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "the reference is unusable");
        (uint256 capped, bool answered) = ctl.balanceClampFor(score, type(uint128).max);
        assertTrue(answered);
        assertEq(capped, 0, "no cap can be computed, so no payout");
        vm.startPrank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        vm.expectPartialRevert(ICore.ReturnLocked.selector);
        core.sellForBalance(_one(id));
        CREDITS.transferFrom(TRIPPER, second, id);
        vm.stopPrank();
        vm.startPrank(second);
        CREDITS.setApprovalForAll(address(core), true);
        vm.expectPartialRevert(ICore.ReturnLocked.selector);
        core.sellForBalance(_one(id));
        vm.stopPrank();
        _setReturnLock(0);
        vm.startPrank(second);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        core.sellForBalance(_one(id));
        vm.stopPrank();
    }

    /// value mode setup with a usable reference, a funded pot and the credit sale open
    function _balanceCapSetup() internal returns (uint256[] memory ids) {
        ids = _fillEthPile(4);
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(5 ether);
        ctl.refreshReference();
    }

    /// the protected sale price per token (wei per 1e18 base units) recovered from the sell side point value
    function _pSell() internal view returns (uint256) {
        (uint256 v,) = ctl.valuePerPoint(true);
        return v * 1e18 / (POINT_UNIT * _moduleUnit());
    }

    function test_pSellHelperMatchesTheController() public {
        _balanceCapSetup();
        uint256 score = 433 * POINT_UNIT;
        (uint256 paid,) = ctl.balanceClampFor(score, type(uint128).max);
        uint256 bid = FullMath.mulDiv(core.ethPrice(), score, RATE_SCORE);
        assertApproxEqRel(FullMath.mulDiv(bid, 1e18, _pSell()), paid, 1e12, "helper pSell matches the controller");
    }

    function _capOf(uint256 score) internal view returns (uint256 cap) {
        uint256 pSell = _pSell();
        cap = FullMath.mulDiv(FullMath.mulDiv(core.ethPrice(), score, RATE_SCORE), 1e18, pSell);
    }

    // promise: the value mode balance cap derives from the value rate before the eth pot clamp, so an eth pot at
    // its reserve does not silence a funded balance module
    function test_balanceCapIgnoresEthPotClamp() public {
        uint256[] memory ids = _balanceCapSetup();
        uint256 id = ids[0];
        uint256 score = _scoreOf(id);
        uint256 cap = _capOf(score);
        assertGt(cap, 0);
        // pot room: the cap is the value rate cap and the view equals the fill
        assertGt(core.bidForScore(score), 0);
        // raise the reserve over the pot so the eth bid is 0
        Settings memory st = core.settings();
        st.reserveWei = 18 ether;
        _setSettings(st);
        assertEq(core.bidForScore(score), 0, "the eth bid is clamped to zero");
        uint256 posted = score * _moduleUnit() * core.balanceRate() / 10_000;
        uint256 want = cap < posted ? cap : posted;
        assertGt(want, 0);
        assertApproxEqRel(core.balanceBidForScore(score), want, 1e12, "the cap is the unclamped value rate cap");
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        _nextSecond();
        _tripBack(id, true);
        assertEq(xt.balanceOf(TRIPPER), core.balanceBidForScore(score), "sellForBalance pays the view");
    }

    // promise: with pot room the cap equals the earlier eth bid based cap, and the view equals the fill
    function test_balanceCapUnchangedWithPotRoom() public {
        uint256[] memory ids = _balanceCapSetup();
        _fundPot(40 ether);
        assertEq(core.ethPrice(), core.ethRate(), "the pot does not clamp");
        uint256 score = _scoreOf(ids[0]);
        uint256 pSell = _pSell();
        uint256 oldCap = FullMath.mulDiv(core.bidForScore(score), 1e18, pSell);
        uint256 cap = _capOf(score);
        assertGe(cap + cap / 1e9, oldCap);
        uint256 posted = score * _moduleUnit() * core.balanceRate() / 10_000;
        uint256 want = cap < posted ? cap : posted;
        assertApproxEqRel(cap, oldCap, 1e12, "equal when the pot does not clamp");
        uint256 viewed = core.balanceBidForScore(score);
        assertApproxEqRel(viewed, want, 1e12);
        uint256 price = ctl.creditPrice(ids[0]);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(ids[0]);
        _nextSecond();
        _tripBack(ids[0], true);
        assertEq(xt.balanceOf(TRIPPER), viewed, "view equals the sell path");
    }

    // promise: with the spot leading the reference the payout valued at pSell never exceeds the unclamped value
    // rate bid, including with the eth pot at its reserve
    function test_balanceCapBoundedByValueRateWhenSpotLeads() public {
        _balanceCapSetup();
        _swapToSpot(ctl.referencePrice() * 355 / 100);
        for (uint256 i; i < 3; ++i) {
            _nextSecond();
            ctl.refreshReference();
        }
        _nextSecond();
        Settings memory st = core.settings();
        st.reserveWei = 18 ether;
        _setSettings(st);
        uint256 score = 433 * POINT_UNIT;
        uint256 pSell = _pSell();
        (uint256 paid,) = ctl.balanceClampFor(score, type(uint128).max);
        assertGt(paid, 0);
        uint256 bid = FullMath.mulDiv(core.ethPrice(), score, RATE_SCORE);
        assertLe(FullMath.mulDiv(paid, pSell, 1e18), bid + bid / 1e9, "payout at pSell is within the unclamped bid");
    }

    // promise: with room under the unclamped bid the balance cap ignores the pot clamp and the fill pays min(posted, cap)
    function test_balanceCapIgnoresPartialPotClamp() public {
        uint256[] memory ids = _balanceCapSetup();
        uint256 id = ids[0];
        uint256 score = _scoreOf(id);
        uint256 full = FullMath.mulDiv(core.ethPrice(), score, RATE_SCORE);
        Settings memory st = core.settings();
        // the clamp room is a rate per 100 points: leave half the unclamped rate in the pot above the reserve
        uint256 room = core.ethPrice() / 2;
        st.reserveWei = uint64(core.ethPot() - room);
        _setSettings(st);
        uint256 clamped = core.bidForScore(score);
        assertGt(clamped, 0);
        assertLt(clamped, full, "the pot clamps the eth bid part way");
        uint256 cap = _capOf(score);
        uint256 posted = score * _moduleUnit() * core.balanceRate() / 10_000;
        uint256 want = cap < posted ? cap : posted;
        assertGt(cap, FullMath.mulDiv(clamped, 1e18, _pSell()), "the cap ignores the clamp");
        uint256 viewed = core.balanceBidForScore(score);
        assertApproxEqRel(viewed, want, 1e12);
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        _nextSecond();
        _tripBack(id, true);
        assertEq(xt.balanceOf(TRIPPER), viewed, "the fill pays the view");
    }

    // promise: SPEC 10 outside value mode the balance payout is par, the clamp does not apply (decision 165). a usable
    // reference quote is set by the fixture, so the clamp would lower the payout if it ran; with value mode off it does not
    function test_balancePayoutIsParOutsideValueMode() public view {
        uint256 score = 433 * POINT_UNIT;
        uint256 par = score * _moduleUnit() * core.balanceRate() / 10_000;
        assertEq(core.balanceBidForScore(score), par, "the balance payout is par outside value mode");
    }

    // promise: SPEC 8 a statement's reference in value mode is valueOf(rating) times floorMultBps, its curve rests there
    function test_statementPricesOffTheProtectedFloor() public {
        Composed memory c = _composeOnce();
        _valueOn();
        uint256 ref = ctl.valueOf(core.ratingOf(c.sid)) * ctl.floorMultBps() / 10_000;
        assertEq(ctl.referenceOf(c.sid), ref);
        vm.warp(block.timestamp + uint256(ctl.decayHours()) * 1 hours);
        ctl.refreshReference();
        ref = ctl.valueOf(core.ratingOf(c.sid)) * ctl.floorMultBps() / 10_000;
        assertEq(ctl.priceOf(c.sid), ref, "the aged curve rests at the protected floor, not at saleFloorBps");
    }

    // promise: a value-mode statement quote executes at the historical cost floor while its reference stays value-only
    function test_statementQuoteCoversHistoricalCostFloor() public {
        Composed memory c = _composeOnce();
        _valueOn();
        vm.warp(block.timestamp + uint256(ctl.decayHours()) * 1 hours);
        vm.roll(block.number + 1);
        uint256 spot = _swapToSpot(ctl.referencePrice() / 100);
        IControllerV1.PoolKey memory k = abi.decode(abi.encode(key), (IControllerV1.PoolKey));
        vm.prank(owner);
        ctl.setBalancePoolKey(k, spot);
        uint256 ref = ctl.valueOf(core.ratingOf(c.sid)) * ctl.floorMultBps() / 10_000;
        uint256 coreFloor = c.cost * core.settings().saleFloorBps / 10_000;
        assertLt(ref, coreFloor, "historical cost dominates protected value");
        assertEq(ctl.referenceOf(c.sid), ref, "reference stays value-only");
        uint256 price = ctl.priceOf(c.sid);
        assertEq(price, coreFloor, "quote covers Core cost floor");
        vm.deal(seller, price);
        vm.prank(seller);
        ctl.buy{value: price}(c.sid);
        assertEq(STATEMENTS.ownerOf(c.sid), seller, "quoted purchase executes");
    }

    // promise: SPEC 8 the controller sale doors move the reference before they price
    function test_saleDoorsObserve() public {
        uint256 id = _fillEthPile(1)[0];
        _setCreditSaleOn(true);
        uint256 ref0 = ctl.referencePrice();
        _swapSpot(10_000);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1); // the sale door's refresh runs at most once per block, past the seed block
        uint256 price = ctl.creditPrice(id);
        vm.deal(seller, price * 2);
        vm.prank(seller);
        ctl.buyCredit{value: price * 2}(id);
        assertEq(ctl.referencePrice(), ref0 * 10_500 / 10_000, "buyCredit moved the reference one 5 percent step");
        assertEq(ctl.referenceTime(), block.timestamp);
    }

    // promise: INTEGRATION gas of the eth door with the extra value read: a one credit sellForEth in value mode costs at
    // most 150,000 gas over the same sale outside it (the controller's bounded read, the module's unit and available)
    function test_sellForEthGasInValueMode() public {
        _fundPot(20 ether);
        uint256[] memory ids = _credits(seller, 1);
        uint256 snap = vm.snapshotState();
        vm.prank(seller);
        uint256 g = gasleft();
        core.sellForEth(ids);
        uint256 plain = g - gasleft();
        vm.revertToState(snap);
        _valueOn();
        vm.prank(seller);
        g = gasleft();
        core.sellForEth(ids);
        uint256 valued = g - gasleft();
        emit log_named_uint("sellForEth gas, one credit, eth instance", plain);
        emit log_named_uint("sellForEth gas, one credit, value mode", valued);
        assertLt(valued, plain + 150_000, "the value read costs at most 150,000 gas a credit");
    }

    // promise: SPEC 11 the switch off reset: the eth instance climbs idle during value mode, so leaving value mode
    // resets it to the shared rate and the eth bid resumes there instead of reopening at the cap
    function test_switchOffResetsEthInstanceToTheSharedRate() public {
        _fundPot(20 ether);
        _valueOn();
        _warp(6 hours); // the shared instance climbs well above the floor while value mode is on
        uint256 valueBid = core.ethRate(); // the eth bid value mode prices now
        Settings memory s = core.settings();
        s.valueModeOn = false;
        _setSettings(s);
        uint256 ethBid = core.ethRate(); // now the eth instance, just reset
        assertApproxEqRel(ethBid, valueBid, 2e16, "the eth bid resumes at the shared rate after the switch off");
        assertLt(ethBid, s.rateCap, "well under the cap, so a rollback cannot reopen the eth bid at the cap");
    }

    // promise: the owner pause stops value-mode direct fills and the same credit can sell after resume
    function test_pauseInValueMode() public {
        _fundPot(20 ether);
        _valueOn();
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(owner);
        core.setPaused(true);
        uint256 before = seller.balance;
        vm.prank(seller);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForEth(ids);
        assertEq(seller.balance, before, "the paused bid does not pay");
        vm.prank(owner);
        core.setPaused(false);
        vm.prank(seller);
        core.sellForEth(ids);
        assertGt(seller.balance, before, "the direct bid resumes");
    }
}

/// the real pool under manipulation: a single block spot swing, just-in-time liquidity against `minLiquidity`, the
/// reference walking at the max rate against a pushed spot, a 10x spike against the rate cap and the pot, and a loop
/// closure round trip at a nonzero quote tolerance. every spot move is a real swap through the pool manager
contract ValueRealPoolTest is ValueBase {
    /// the nonzero-band fixture quote with `minLiquidity` replaced
    function _quoteWithMinLiquidity(uint128 minLiq) internal pure returns (Quote memory) {
        return Quote({
            referenceRateBpsPerHour: 1_000,
            referenceStepBps: 500,
            tolBps: 450,
            referenceMaxStale: 1 days,
            referenceMinSeconds: 0,
            minLiquidity: minLiq
        });
    }

    // promise: at zero tolerance a real pool move stays out of the same-block quote, while one scheduled refresh may move the reference by two percent
    function test_zeroToleranceUsesSampledSpotAndTwoPercentRefreshStep() public {
        _setQuote(Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 0,
            referenceMaxStale: 3_600,
            referenceMinSeconds: 600,
            minLiquidity: 1e18
        }));
        _fundPot(20 ether); // real coin trading creates the hook fees that fund this bid
        _valueOn();
        uint256[] memory ids = _credits(seller, 1);
        uint256 bid0 = core.bidOf(ids[0]);
        uint256 ref0 = ctl.referencePrice();
        (uint256 buy0, bool ok0) = ctl.valuePerPoint(false);
        assertTrue(ok0);
        _swapSpot(1_000);
        (uint256 sameBlock, bool okSameBlock) = ctl.valuePerPoint(false);
        assertTrue(okSameBlock);
        assertEq(sameBlock, buy0, "the live spot cannot lift the same-block bid");
        assertEq(core.bidOf(ids[0]), bid0, "the real sell door keeps the pre-swap bid");
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - sellerBefore, bid0, "the seller receives the recorded bid");
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);
        ctl.refreshReference();
        assertEq(ctl.referencePrice(), ref0 * 10_200 / 10_000, "one refresh moves the two percent step");
        (uint256 refreshBlockBuy,) = ctl.valuePerPoint(false);
        assertEq(refreshBlockBuy, buy0, "the refresh block still uses the prior spot sample");
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        (uint256 buy1, bool okBuy) = ctl.valuePerPoint(false);
        (uint256 sell1, bool okSell) = ctl.valuePerPoint(true);
        assertTrue(okBuy && okSell);
        assertGt(buy1, buy0, "the scheduled step can still lift the bid");
        assertLt(buy1, sell1, "the sale uses the sampled spot above the reference");
    }

    // promise: at 100 bps tolerance a real 10 percent up-move keeps the bid below spot and the ask at spot until
    // the reference catches up within five eligible 600-second refreshes
    function test_realPoolUpMoveStaleQuoteClosesWithinFiveRefreshes() public {
        _testStaleQuoteMove(1_000);
    }

    // promise: at 100 bps tolerance a real 10 percent down-move keeps the bid at spot and the ask above spot until
    // the reference catches up within five eligible 600-second refreshes
    function test_realPoolDownMoveStaleQuoteClosesWithinFiveRefreshes() public {
        _testStaleQuoteMove(-1_000);
    }

    function _testStaleQuoteMove(int256 moveBps) internal {
        _setQuote(Quote({
            referenceRateBpsPerHour: 1_200,
            referenceStepBps: 200,
            tolBps: 100,
            referenceMaxStale: 3_600,
            referenceMinSeconds: 600,
            minLiquidity: 1e18
        }));
        uint256 opening = ctl.referencePrice();
        uint256 spot = _swapSpot(moveBps);
        uint256 target = moveBps > 0 ? opening * 11_000 / 10_000 : opening * 9_000 / 10_000;
        assertApproxEqRel(spot, target, 1e15, "the real swap moves spot by about 10 percent");
        uint256 unit = mod.unitPerPoint();
        uint256 spotBid = FullMath.mulDiv(POINT_UNIT * unit, spot, 1e18);
        uint256 spotAsk = FullMath.mulDivRoundingUp(POINT_UNIT * unit, spot, 1e18);

        for (uint256 i = 1; i <= 5; ++i) {
            vm.warp(block.timestamp + 600);
            vm.roll(block.number + 1);
            assertTrue(ctl.refreshReference(), "the scheduled refresh moves the reference");
            // The refresh block still uses the old sample. The next block prices against the held market move.
            vm.roll(block.number + 1);
            (uint256 bid, bool buyOk) = ctl.valuePerPoint(false);
            (uint256 ask, bool sellOk) = ctl.valuePerPoint(true);
            assertTrue(buyOk && sellOk, "both real-pool quotes remain usable");
            if (moveBps > 0) {
                assertEq(ask, spotAsk, "the up-move ask uses the sampled spot");
                if (i == 1) assertLt(bid, spotBid, "the up-move bid lags the sampled spot");
            } else {
                assertEq(bid, spotBid, "the down-move bid uses the sampled spot");
                if (i == 1) assertGt(ask, spotAsk, "the down-move ask lags the sampled spot");
            }
            if (i == 5) {
                assertEq(bid, spotBid, "the bid reaches spot within five refreshes");
                assertEq(ask, spotAsk, "the ask reaches spot within five refreshes");
            }
        }
    }

    // promise: SPEC 8 a single block spot swing around a victim trade cannot move the priced value past the band: a
    // spike up lifts the buy value by at most tolBps and a crash down drops the sale value by at most tolBps, not toward
    // the manipulated spot. the swaps and the victim trade share one block
    function test_singleBlockManipulationStaysInsideTheBand() public {
        uint256 id = _fillEthPile(1)[0];
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        ctl.refreshReference();
        uint256 ref = ctl.referencePrice();
        uint256 victim = _credits(seller, 1)[0];

        // an attacker spikes the spot up, the victim sells into the eth bid, the attacker restores, all in one block
        (uint256 vBuy0,) = ctl.valuePerPoint(false);
        _swapSpot(10_000);
        (uint256 vBuy1,) = ctl.valuePerPoint(false);
        assertLe(vBuy1, vBuy0 * 10_460 / 10_000, "the spike up lifts the buy value by at most the 4.5 percent band");
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(victim));
        assertGt(seller.balance - before, 0, "the victim sell fills through the manipulated block");
        _swapToSpot(ref);

        // an attacker crashes the spot, a buyer prices a credit: the price drops by at most the band, not to the spot
        uint256 price0 = ctl.creditPrice(id);
        _swapSpot(-7_000);
        uint256 price1 = ctl.creditPrice(id);
        assertGe(price1 * 10_000, price0 * 9_500, "the crash drops the price by at most the band, not toward the spot");
        _swapToSpot(ref);
    }

    // promise: SPEC 8 the minLiquidity gate reads the live pool depth; just-in-time liquidity added in the same block
    // lifts the pool above the minimum and makes the quote usable, the known ceiling of a block local liquidity check
    // promise: the quote reads the liquidity sampled at the last refresh, so a one-block add cannot open it (C04)
    function test_jitLiquidityCannotPassMinLiquidity() public {
        uint128 liq0 = _liquidityNow();
        _setQuote(_quoteWithMinLiquidity(liq0 + uint128(POOL_LIQ)));
        (, bool ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "the quote is unusable while the sampled depth is under the raised minimum");
        _addFullRange(int256(uint256(POOL_LIQ)));
        assertGe(_liquidityNow(), liq0 + POOL_LIQ, "the just-in-time add deepened the live pool");
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "a one-block add does not change the sampled liquidity, so the quote stays closed");
        _setQuote(_quoteWithMinLiquidity(1e18));
    }

    // promise: SPEC 8 refreshing every block at the max rate for an hour against a spot pushed far above walks the
    // reference up by about the hourly rate and never past the spot, so block by block spam gains nothing beyond the rate
    function test_referenceWalksAtTheMaxRateForAnHour() public {
        uint256 ref0 = ctl.referencePrice();
        uint256 spot = _swapSpot(20_000); // a real swap pushes the spot to about three times the reference
        for (uint256 i; i < 300; ++i) {
            vm.warp(block.timestamp + 12);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
        uint256 ref1 = ctl.referencePrice();
        assertGt(ref1, ref0, "the reference walked toward the pushed spot");
        assertLe(ref1, spot, "but never past the spot");
        assertApproxEqRel(ref1, ref0 * 11_000 / 10_000, 2e16, "an hour at 1,000 bps an hour moved about 10 percent");
        assertLe(ref1, ref0 * 11_050 / 10_000, "and never beyond the compounded hourly rate");
    }

    // promise: SPEC 1 a 10x spot spike in one block lifts the eth buy value by at most the band, so the eth bid stays
    // under the rate cap and inside the pot: the protected buy price caps the spike at reference plus the band
    function test_tenXSpotSpikeStaysUnderTheRateCapAndPot() public {
        _fundPot(20 ether);
        _valueOn();
        _warp(2 hours);
        ctl.refreshReference();
        uint256 ref = ctl.referencePrice();
        (uint256 vBuy0,) = ctl.valuePerPoint(false);
        uint256 bid0 = core.ethRate();
        _swapToSpot(ref * 10); // a real swap spikes the spot ten fold in one block
        (uint256 vBuy1,) = ctl.valuePerPoint(false);
        uint256 bid1 = core.ethRate();
        Settings memory s = core.settings();
        assertLe(vBuy1, vBuy0 * 10_460 / 10_000, "the buy value rises by at most the band, not ten fold");
        assertLe(bid1, s.rateCap, "the eth bid stays under the rate cap through the spike");
        assertLe(bid1, bid0 * 10_460 / 10_000 + 1, "the eth bid rises by at most the band");
        assertLe(bid1, core.ethPot(), "the eth bid rides the pot");
    }

    // promise: SPEC 10 a credit bought from the engine at a nonzero-band quote floor and sold straight back loses at least
    // the credit spread. the eth worst case is printed
    function test_loopClosureRoundTripAtNonzeroBand() public {
        uint256 id = _fillEthPile(1)[0];
        _valueOn();
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
        ctl.refreshReference();

        uint256 price = ctl.creditPrice(id);
        vm.deal(address(this), 100 ether);
        uint256 b0 = address(this).balance;
        ctl.buyCredit{value: price * 2}(id);
        uint256 paid = b0 - address(this).balance;
        _nextSecond();
        CREDITS.setApprovalForAll(address(core), true);
        uint256 b1 = address(this).balance;
        core.sellForEth(_one(id));
        uint256 back = address(this).balance - b1;

        assertGt(back, 0, "the round trip returned eth");
        uint256 m = 10_000 + ctl.creditSpreadBps();
        assertLe(back * m, (paid + 1) * 10_000, "a launch value round trip loses at least the spread");
        emit log_named_uint("loop closure: eth paid to buy the credit", paid);
        emit log_named_uint("loop closure: eth returned on the sell back", back);
        emit log_named_uint("loop closure: eth lost on the round trip", paid - back);
    }
}
