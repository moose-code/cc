// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// the price reference of the sale controller on the live fork. `referenceOf(sid)` is the larger of a statement's cost
/// and the floor rate times its rating over `refScore`, computed at each call. the floor rate is the larger of the
/// climbed price state and the decayed peak. the sale curve,
/// its floor, the anchor and `atFloor` all price in bps of the reference. the rate term prices the rating at the
/// engine's average credit price, so two statements of the same rating reference the same amount once it binds,
/// whatever each credit cost. real Core, ControllerV1, Statements
contract RatingReferenceTest is Fixture {
    uint256 internal constant BPS = 10_000;
    uint32 internal constant MAX_REF_SCORE = 8_000_000;
    /// a small sqrt price makes the balance token expensive in eth, so the redeemable value floor is large
    uint160 internal constant LOW_SQRT = uint160(FixedPoint96.Q96 / 1000);
    /// a large sqrt price makes the balance token cheap in eth, so a balance token bought credit records its score-scaled
    /// backstop as its eth cost, a moderate figure above the eth lineage cost
    uint160 internal constant HIGH_SQRT = uint160((uint256(1) << 96) * 1000);

    function _setRef(uint32 v) internal {
        vm.prank(owner);
        ctl.setRefScore(v);
    }

    /// lowers `refScore` so statement `sid` references about four times its cost (the rate term binds), and returns the
    /// reference and the cost
    function _makeRich(uint256 sid) internal returns (uint256 ref, uint256 cost) {
        (, cost,) = core.statementInfo(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 p = core.floorRate();
        // the refScore at which the rate term equals the cost, then a quarter of it so the rate term is about four
        // times the cost
        uint256 cross = FullMath.mulDiv(p, rating, cost);
        uint32 rs = uint32(cross / 4);
        if (rs == 0) rs = 1;
        _setRef(rs);
        ref = ctl.referenceOf(sid);
        assertGt(ref, cost, "the test statement is rich");
    }

    /// composes a fresh statement from 80 eth bought credits
    function _composeEthPage() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    /// composes a fresh statement from 80 balance token bought credits. needs the balance side on, the balance pool set and the redemption
    /// pot funded
    function _composeBalancePage() internal returns (uint256 sid) {
        uint256[] memory xIds = _credits(seller, 80);
        vm.prank(seller);
        core.sellForBalance(xIds);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    function _initPool(uint160 sp) internal {
        PoolKey memory vk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(vk, sp);
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k);
    }

    // ------------------------------------------------------------------ reference

    function test_launchRefScoreIsTheAverage() public view {
        assertEq(ctl.refScore(), 4_330_000, "launch refScore is the average credit score");
    }

    /// the reference is the larger of cost and the rate term `floorRate * rating / refScore`. a high refScore shrinks
    /// the rate term below cost so cost binds, a low refScore lifts it above cost so it binds, and when it binds the
    /// reference equals it exactly
    function test_reference_isMaxOfCostAndRateTerm() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 p = core.floorRate();
        assertGt(p, 0, "the floor rate is nonzero");

        _setRef(MAX_REF_SCORE);
        uint256 rateHi = FullMath.mulDiv(p, rating, MAX_REF_SCORE);
        assertEq(ctl.referenceOf(sid), rateHi > cost ? rateHi : cost, "the reference is the max of cost and the rate term");

        _setRef(1);
        uint256 rateLo = FullMath.mulDiv(p, rating, 1);
        assertGt(rateLo, cost, "the rate term at refScore 1 exceeds cost");
        assertEq(ctl.referenceOf(sid), rateLo, "the reference is the rate term exactly when it binds");
    }

    /// crossing the boundary where the rate term equals cost: one unit of refScore above it references cost, one unit
    /// below it references the rate term
    function test_reference_boundaryBetweenCostAndRateTerm() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 p = core.floorRate();

        // the largest refScore whose rate term is at least cost
        uint256 cross = FullMath.mulDiv(p, rating, cost);
        assertGt(cross, 1, "the boundary refScore is above the minimum for this fixture");
        assertLt(cross, MAX_REF_SCORE, "the boundary refScore is within the setting bound for this fixture");

        _setRef(uint32(cross));
        assertEq(ctl.referenceOf(sid), FullMath.mulDiv(p, rating, cross), "at the boundary the rate term binds");
        assertGe(ctl.referenceOf(sid), cost, "the rate term at the boundary is at least cost");

        _setRef(uint32(cross + 1));
        assertEq(ctl.referenceOf(sid), cost, "one unit above the boundary references cost");
    }

    /// the bug decision 95 fixes: an eth bought statement and a balance token bought statement reference by the same
    /// per-rating amount once the rate term binds, whatever each credit cost. decision 90 scaled the redemption statement by
    /// about the square of its score ratio because its recorded cost already scaled with score
    function test_sameRatingSameReference_acrossLineages() public {
        _enterPhase2();
        xt.mint(address(core), 1e27);
        core.bookBalance();
        _fundPot(5 ether);
        _initPool(HIGH_SQRT); // the cheap balance token records the score-scaled backstop as the redemption lineage cost

        uint256 ethSid = _composeEthPage();
        uint256 balanceSid = _composeBalancePage();

        (, uint256 costE,) = core.statementInfo(ethSid);
        (, uint256 costX,) = core.statementInfo(balanceSid);
        // the eth lineage records the dropped eth bid, the redemption lineage its score-scaled backstop: two different cost
        // bases, where decision 90 scaled each statement by its own cost
        assertTrue(costX != costE, "the two lineages record different cost bases");

        _setRef(1); // the smallest refScore, so the rate term binds for both lineages

        uint256 p = core.floorRate();
        uint256 re = core.ratingOf(ethSid);
        uint256 rx = core.ratingOf(balanceSid);

        // the reference is the rate term for both, cost absent
        assertEq(ctl.referenceOf(ethSid), FullMath.mulDiv(p, re, 1), "the eth lineage references the rate term");
        assertEq(ctl.referenceOf(balanceSid), FullMath.mulDiv(p, rx, 1), "the redemption lineage references the rate term");
        assertGt(ctl.referenceOf(ethSid), costE, "the rate term binds above the eth lineage cost");
        assertGt(ctl.referenceOf(balanceSid), costX, "the rate term binds above the redemption lineage cost");

        // equal rating gives equal reference: scaling the eth reference to the redemption rating lands on the redemption reference,
        // so the higher redemption cost does not lift it
        assertEq(
            FullMath.mulDiv(ctl.referenceOf(ethSid), rx, re),
            ctl.referenceOf(balanceSid),
            "a statement of equal rating references equally whatever its credits cost"
        );
    }

    /// the reference moves with the floor rate at the call. raising the stored rate raises the reference and the curve
    /// price in step, and `atFloor` stays an age decision through the move
    function test_referenceMovesWithTheFloorRate() public {
        uint256 sid = _composeOnce().sid;
        _setRef(1); // the rate term binds
        uint256 rating = core.ratingOf(sid);

        uint256 p1 = core.floorRate();
        assertEq(ctl.referenceOf(sid), p1 * rating, "the reference is the rate term at the current floor rate");
        uint256 price1 = ctl.priceOf(sid);
        bool floor1 = ctl.atFloor(sid);

        _liftRateCap();
        vm.prank(owner);
        core.setRate(p1 * 2);
        uint256 p2 = core.floorRate();
        assertGt(p2, p1, "the floor rate moved up");

        assertEq(ctl.referenceOf(sid), p2 * rating, "the reference followed the floor rate at the call");
        assertEq(ctl.priceOf(sid), price1 * p2 / p1, "the curve price followed the reference");
        assertEq(ctl.atFloor(sid), floor1, "atFloor is an age decision, unchanged by the floor rate move");
    }

    /// a large sale walks the clamped bid down and drops the climbed price state, but the peak does not fall in one tx,
    /// so the floor rate holds at the peak and a statement's reference is unchanged
    function test_largeSaleLeavesThePeakAndReferenceUnchanged() public {
        _liftRateCap();
        _fundPot(50 ether);
        uint256 sid = _composeOnce().sid;
        // a modest, stable peak the pot can afford to buy 115 credits against
        vm.prank(owner);
        core.setRate(0.05 ether);
        _setRef(1); // the rate term binds, so the reference tracks the floor rate
        uint256 floor0 = core.floorRate();
        uint256 ref0 = ctl.referenceOf(sid);
        assertEq(ref0, floor0 * core.ratingOf(sid), "the reference is the floor rate times the rating");

        // sell 115 credits into the eth bid in one call; the clamped bid walks down a credit at a time
        uint256[] memory ids = _credits(seller, 115);
        vm.prank(seller);
        core.sellForEth(ids);

        assertLt(core.ethRate(), floor0, "the sale walked the clamped bid down");
        assertLt(core.ethPrice(), floor0, "the sale dropped the climbed price state below the peak");
        assertEq(core.floorRate(), floor0, "the floor rate held at the peak through the batch");
        assertEq(ctl.referenceOf(sid), ref0, "the statement reference is unchanged");
    }

    /// a long idle with no fills decays the peak and climbs the price state, so the floor rate rises to the climbed
    /// rate and a statement's reference rises with it
    function test_longIdleLiftsTheFloorRateAndReference() public {
        _liftRateCap();
        _fundPot(50 ether);
        uint256 sid = _composeOnce().sid;
        vm.prank(owner);
        core.setRate(0.05 ether);
        _setRef(1); // the rate term binds, so the reference tracks the floor rate
        uint256 floor0 = core.floorRate();
        uint256 ref0 = ctl.referenceOf(sid);

        _warp(2 days); // no fills: the peak decays, the price state climbs

        uint256 climbed = core.ethPrice();
        assertGt(climbed, floor0, "the price state climbed above the opening peak");
        assertEq(core.floorRate(), climbed, "the floor rate is the climbed rate, the decayed peak is below it");
        assertEq(ctl.referenceOf(sid), climbed * core.ratingOf(sid), "the reference followed the climbed floor rate");
        assertGt(ctl.referenceOf(sid), ref0, "the reference rose with the idle climb");
    }

    // ------------------------------------------------------------------ curve, floor and eligibility

    function test_curvePointsScaleWithReference() public {
        uint256 sid = _composeOnce().sid;
        _makeRich(sid);

        // lower the core hard floor `cost * saleFloorBps` so the curve points below, each a fraction of the reference,
        // measure the curve and not the hard floor
        Settings memory s = core.settings();
        s.saleFloorBps = 1_000;
        _setSettings(s);

        // a two stage curve: start 15000, knee 7500, floor 5000 of the reference
        vm.startPrank(owner);
        ctl.setFloorBps(5_000);
        ctl.setKneeBps(7_500);
        vm.stopPrank();

        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * ctl.startBps() / BPS, "the start is startBps of the reference");

        _warp(75 hours); // fast decay 15000 to 7500 at 100 per hour
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * 7_500 / BPS, "the knee is kneeBps of the reference");

        _warp(400 hours);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * 5_000 / BPS, "the floor is floorBps of the reference");
    }

    /// a rich statement's floor is the scaled reference and `atFloor` flips when the curve reaches it, at a price above
    /// cost, where the old at-cost rule would never hold
    function test_richFloorIsTheScaledReferenceAndAtFloorFlipsThere() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost) = _makeRich(sid);
        assertGt(ctl.referenceOf(sid) * ctl.floorBps() / BPS, cost, "the scaled floor sits above cost");

        assertFalse(ctl.atFloor(sid), "a fresh statement is above its floor");
        assertGt(ctl.priceOf(sid), ctl.referenceOf(sid) * ctl.floorBps() / BPS, "the opening price is above the floor");

        _warp(49 hours);
        assertFalse(ctl.atFloor(sid), "one hour before the floor it is still above");

        _warp(1 hours); // the launch curve reaches its floor at hour 50
        assertTrue(ctl.atFloor(sid), "the curve has reached its floor");
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * ctl.floorBps() / BPS, "the price rests at the scaled floor");
    }

    // ------------------------------------------------------------------ anchor

    /// the anchor measures a sale in bps of the reference. a rich statement sold at a markup equal to the anchor leaves
    /// the anchor unchanged, where a cost based measure would push it up
    function test_anchorIgnoresARichSaleAtTheAnchorMarkup() public {
        uint256 sid = _composeOnce().sid;
        (uint256 ref, uint256 cost) = _makeRich(sid);
        vm.startPrank(owner);
        ctl.setAnchorMinCost(0);
        ctl.setMarkupBps(10_000); // the start price equals the anchor
        ctl.setAnchorBps(12_000);
        vm.stopPrank();

        uint256 price = ctl.priceOf(sid);
        assertLe(price * BPS / ref, 12_000, "the sale price in bps of the reference is at the anchor");
        assertGt(price * BPS / cost, 12_000, "in bps of cost it would be above the anchor");

        address buyer = _user("buyer");
        vm.deal(buyer, price);
        vm.prank(buyer);
        ctl.buy{value: price}(sid);
        assertEq(ctl.anchorBps(), 12_000, "a sale at the anchor markup leaves the anchor unchanged");
    }

    /// a sale above the anchor moves it to the mean, measured in bps of the reference, not cost
    function test_anchorMovesOnASaleAboveTheAnchor() public {
        uint256 sid = _composeOnce().sid;
        (uint256 ref,) = _makeRich(sid);
        vm.startPrank(owner);
        ctl.setAnchorMinCost(0);
        ctl.setMarkupBps(15_000); // the start price is 1.5 times the anchor
        ctl.setAnchorBps(12_000);
        vm.stopPrank();

        uint256 price = ctl.priceOf(sid);
        assertEq(price, ref * 18_000 / BPS, "the start is 18000 bps of the reference");

        address buyer = _user("buyer");
        vm.deal(buyer, price);
        vm.prank(buyer);
        ctl.buy{value: price}(sid);
        assertEq(ctl.anchorBps(), 15_000, "the anchor moves to the mean of 12000 and 18000");
    }

    // ------------------------------------------------------------------ core hard floor and value floor

    /// the core hard floor is saleFloorBps of cost, enforced by the core whatever the controller quotes, even for a
    /// rich statement whose reference exceeds cost
    function test_coreHardFloorBoundsAtCost() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        _makeRich(sid);
        Settings memory s = core.settings();
        uint256 floor = cost * s.saleFloorBps / BPS;
        address buyer = _user("buyer");

        vm.deal(address(ctl), floor);
        vm.prank(address(ctl));
        vm.expectRevert(ICore.BelowFloor.selector);
        core.sellTo{value: floor - 1}(sid, buyer);

        vm.deal(address(ctl), floor);
        vm.prank(address(ctl));
        core.sellTo{value: floor}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer, "the sale at the cost floor lands");
    }

    /// the decision 87 value floor still wins over the scaled curve when the redemption value is above it
    function test_valueFloorWinsOverTheScaledCurve() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _makeRich(sid);
        uint256 curve = ctl.priceOf(sid);

        _initPool(LOW_SQRT); // a low sqrt price makes the balance token expensive in eth
        uint256 owed = core.ratingOf(sid) * core.unitPerPoint();
        uint256 q = FixedPoint96.Q96;
        uint256 value = FullMath.mulDiv(FullMath.mulDiv(owed, q, LOW_SQRT), q, LOW_SQRT);

        assertGt(value, curve, "the value floor is above the scaled curve");
        assertEq(ctl.priceOf(sid), value, "the asking price is the value floor");
    }

    // ------------------------------------------------------------------ setter

    function test_refScoreChangeAppliesToOpenListingsAtOnce() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 p = core.floorRate();
        uint256 cross = FullMath.mulDiv(p, rating, cost);

        _setRef(MAX_REF_SCORE); // a high refScore keeps the reference at cost
        assertEq(ctl.referenceOf(sid), cost, "the reference is the cost under a high refScore");

        uint32 rich = uint32(cross / 2);
        if (rich == 0) rich = 1;
        _setRef(rich);
        assertEq(
            ctl.referenceOf(sid),
            FullMath.mulDiv(p, rating, rich),
            "the reference is computed at the call from the current refScore"
        );
        assertGt(ctl.referenceOf(sid), cost, "a lowered refScore lifts the open listing above cost");
    }

    function test_setRefScore_boundsEventAndOwner() public {
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setRefScore(1_000);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("refScore")));
        ctl.setRefScore(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("refScore")));
        ctl.setRefScore(MAX_REF_SCORE + 1);

        vm.expectEmit(address(ctl));
        emit IControllerV1.RefScoreSet(1_234_567);
        vm.prank(owner);
        ctl.setRefScore(1_234_567);
        assertEq(ctl.refScore(), 1_234_567, "the setter stores the value");

        _setRef(MAX_REF_SCORE); // the bound is inclusive
        assertEq(ctl.refScore(), MAX_REF_SCORE, "the max is accepted");
    }
}
