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

/// the rating scaled price reference of the sale controller on the live fork. `referenceOf(sid)` is the statement cost
/// scaled by `rating / (80 * refScore)` above the threshold and the cost at or below it. the sale curve, its floor, the
/// anchor and `atFloor` all price in bps of the reference. real Core, ControllerV1, Statements
contract RatingReferenceTest is Fixture {
    uint256 internal constant BPS = 10_000;
    uint32 internal constant MAX_REF_SCORE = 8_000_000;

    function _setRef(uint32 v) internal {
        vm.prank(owner);
        ctl.setRefScore(v);
    }

    /// lowers `refScore` so statement `sid` references several times its cost, and returns the reference
    function _makeRich(uint256 sid) internal returns (uint256 ref, uint256 cost) {
        (, cost,) = core.statementInfo(sid);
        uint32 rs = uint32(core.ratingOf(sid) / 400);
        if (rs == 0) rs = 1;
        _setRef(rs);
        ref = ctl.referenceOf(sid);
        assertGt(ref, cost, "the test statement is rich");
    }

    /// composes a fresh statement from the pile, refilling to a full page first
    function _composeNew() internal returns (uint256 sid) {
        uint256 size = core.pileSize();
        if (size < 80) _fillEthPile(80 - size);
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
        ctl.setExitPoolKey(k);
    }

    // ------------------------------------------------------------------ reference

    function test_launchRefScoreIsTheAverage() public view {
        assertEq(ctl.refScore(), 4_330_000, "launch refScore is the average credit score");
    }

    /// rating below, at and above `80 * refScore` references cost, cost and the scaled cost. the transition is at
    /// `rating == 80 * refScore`: one unit of `refScore` below the boundary scales
    function test_reference_belowAtAboveThreshold() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 r = core.ratingOf(sid);

        uint32 rsBelow = uint32(r / 80 + 1); // 80 * rsBelow > r
        _setRef(rsBelow);
        assertGt(80 * uint256(rsBelow), r, "rating below the threshold");
        assertEq(ctl.referenceOf(sid), cost, "rating below the threshold references cost");

        uint32 rsAt = uint32((r + 79) / 80); // smallest refScore with r <= 80 * refScore
        _setRef(rsAt);
        assertLe(r, 80 * uint256(rsAt), "rating at or below the threshold");
        assertEq(ctl.referenceOf(sid), cost, "rating at the threshold references cost");

        uint32 rsAbove = uint32((r - 1) / 80); // 80 * rsAbove < r
        _setRef(rsAbove);
        uint256 denom = 80 * uint256(rsAbove);
        assertGt(r, denom, "rating above the threshold");
        assertEq(ctl.referenceOf(sid), FullMath.mulDiv(cost, r, denom), "rating above the threshold scales the cost");
        assertGt(ctl.referenceOf(sid), cost, "the scaled reference exceeds cost");

        _setRef(rsAt - 1); // one unit below the boundary scales
        assertGt(r, 80 * uint256(rsAt - 1), "one unit below the boundary is above the threshold");
        assertGt(ctl.referenceOf(sid), cost, "one unit below the boundary scales the reference");
    }

    function test_refScoreChangeAppliesToOpenListingsAtOnce() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 r = core.ratingOf(sid);

        _setRef(uint32(r / 80 + 1));
        assertEq(ctl.referenceOf(sid), cost, "the reference is the cost under a high refScore");

        uint32 rich = uint32(r / 160);
        _setRef(rich);
        assertEq(
            ctl.referenceOf(sid),
            FullMath.mulDiv(cost, r, 80 * uint256(rich)),
            "the reference is computed at the call from the current refScore"
        );
        assertGt(ctl.referenceOf(sid), cost, "a lowered refScore scales the open listing");
    }

    // ------------------------------------------------------------------ curve, floor and eligibility

    function test_curvePointsScaleWithReference() public {
        uint256 sid = _composeOnce().sid;
        (uint256 ref,) = _makeRich(sid);

        // a two stage curve: start 15000, knee 7500, floor 5000 of the reference
        vm.startPrank(owner);
        ctl.setFloorBps(5_000);
        ctl.setKneeBps(7_500);
        vm.stopPrank();

        assertEq(ctl.priceOf(sid), ref * ctl.startBps() / BPS, "the start is startBps of the reference");

        _warp(75 hours); // fast decay 15000 to 7500 at 100 per hour
        assertEq(ctl.priceOf(sid), ref * 7_500 / BPS, "the knee is kneeBps of the reference");

        _warp(400 hours);
        assertEq(ctl.priceOf(sid), ref * 5_000 / BPS, "the floor is floorBps of the reference");
    }

    /// a rich statement's floor is the scaled reference and `atFloor` flips when the curve reaches it, at a price above
    /// cost, where the old at-cost rule would never hold
    function test_richFloorIsTheScaledReferenceAndAtFloorFlipsThere() public {
        uint256 sid = _composeOnce().sid;
        (uint256 ref, uint256 cost) = _makeRich(sid);
        uint256 floorPrice = ref * ctl.floorBps() / BPS;
        assertGt(floorPrice, cost, "the scaled floor sits above cost");

        assertFalse(ctl.atFloor(sid), "a fresh statement is above its floor");
        assertGt(ctl.priceOf(sid), floorPrice, "the opening price is above the floor");

        _warp(49 hours);
        assertFalse(ctl.atFloor(sid), "one hour before the floor it is still above");

        _warp(1 hours); // the launch curve reaches its floor at hour 50
        assertTrue(ctl.atFloor(sid), "the curve has reached its floor");
        assertEq(ctl.priceOf(sid), floorPrice, "the price rests at the scaled floor");
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
        uint256 sid = _composeNew();
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

        uint160 sp = uint160(FixedPoint96.Q96 / 1000); // a low sqrt price makes the exit token expensive in eth
        _initPool(sp);
        uint256 owed = core.ratingOf(sid) * core.unitPerPoint();
        uint256 q = FixedPoint96.Q96;
        uint256 value = FullMath.mulDiv(FullMath.mulDiv(owed, q, sp), q, sp);

        assertGt(value, curve, "the value floor is above the scaled curve");
        assertEq(ctl.priceOf(sid), value, "the asking price is the value floor");
    }

    // ------------------------------------------------------------------ setter

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
