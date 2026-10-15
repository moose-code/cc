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
/// and `valueOf(rating)`, computed at each call. `valueOf` is the larger of the rate term, the floor rate times the
/// rating over `refScore`, and the balance token pool term. the floor rate is the larger of the climbed price state and
/// the decayed peak. the sale curve, its floor `saleFloorBps`, the anchor and `atFloor` all price in bps of the
/// reference. the rate term prices the rating at the engine's average credit price, so two statements of the same
/// rating reference the same amount once it binds, whatever each credit cost. real Core, ControllerV1, Statements
contract RatingReferenceTest is Fixture {
    uint256 internal constant BPS = 10_000;
    uint32 internal constant MIN_REF_SCORE = 800_000;
    uint32 internal constant MAX_REF_SCORE = 8_000_000;
    /// a small sqrt price makes the balance token expensive in eth, so the pool term is large
    uint160 internal constant LOW_SQRT = uint160(FixedPoint96.Q96 / 1000);
    /// a large sqrt price makes the balance token cheap in eth, so a balance token bought credit records its score-scaled
    /// backstop as its eth cost, a moderate figure above the eth lineage cost
    uint160 internal constant HIGH_SQRT = uint160((uint256(1) << 96) * 1000);

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
        if (rs < MIN_REF_SCORE) rs = MIN_REF_SCORE;
        _setRefScore(rs);
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

    // promise: SPEC 1 one pricing rule: pointRate and valueOf (decision 104)
    /// `pointRate` is the floor rate over `refScore` and `valueOf` is its product with the points at full precision
    function test_pointRateAndValueOf() public {
        uint256 p = core.floorRate();
        assertEq(ctl.pointRate(), p / ctl.refScore(), "the point rate is the floor rate over refScore");
        assertEq(ctl.valueOf(0), 0, "no points, no value");
        assertEq(ctl.valueOf(1_000_000), FullMath.mulDiv(p, 1_000_000, ctl.refScore()), "one division on the product");
        assertGe(ctl.valueOf(ctl.refScore()), ctl.pointRate() * ctl.refScore(), "the product keeps the remainder");
        assertEq(ctl.valueOf(ctl.refScore()), p, "refScore points are worth the floor rate");
    }

    // promise: SPEC 1 refScore is bounded 800,000 to 8,000,000
    /// the owner cannot set the reference score under its lower bound or over its upper bound, and both bounds are accepted
    function test_refScore_boundsAreEnforced() public {
        Settings memory s = core.settings();
        s.refScore = MIN_REF_SCORE - 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("refScore")));
        core.setSettings(s);
        s.refScore = MAX_REF_SCORE + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, bytes32("refScore")));
        core.setSettings(s);
        _setRefScore(MIN_REF_SCORE);
        _setRefScore(MAX_REF_SCORE);
    }

    // promise: SPEC 1 the statement reference is max(cost, valueOf(rating))
    /// the reference is the larger of cost and the rate term `floorRate * rating / refScore`. a high refScore shrinks
    /// the rate term below cost so cost binds, a low refScore lifts it above cost so it binds, and when it binds the
    /// reference equals it exactly
    function test_reference_isMaxOfCostAndRateTerm() public {
        uint256 sid = _composeOnce().sid;
        (, uint256 cost,) = core.statementInfo(sid);
        uint256 rating = core.ratingOf(sid);
        uint256 p = core.floorRate();
        assertGt(p, 0, "the floor rate is nonzero");

        _setRefScore(MAX_REF_SCORE);
        uint256 rateHi = FullMath.mulDiv(p, rating, MAX_REF_SCORE);
        assertEq(ctl.referenceOf(sid), rateHi > cost ? rateHi : cost, "the reference is the max of cost and the rate term");

        _setRefScore(MIN_REF_SCORE);
        uint256 rateLo = FullMath.mulDiv(p, rating, MIN_REF_SCORE);
        assertGt(rateLo, cost, "the rate term at the lowest refScore exceeds cost");
        assertEq(ctl.referenceOf(sid), rateLo, "the reference is the rate term exactly when it binds");
    }

    // promise: SPEC 1 one pile: equal ratings reference equally (decision 95)
    /// the bug decision 95 fixes: an eth bought statement and a balance token bought statement reference by the same
    /// per-rating amount once the rate term binds, whatever each credit cost. decision 90 scaled the redemption statement by
    /// about the square of its score ratio because its recorded cost already scaled with score
    function test_sameRatingSameReference_acrossLineages() public {
        _enterPhase2();
        xt.mint(address(mod), 1e27);
        _fundPot(5 ether);
        _initPool(HIGH_SQRT); // the cheap balance token records the score-scaled backstop as the redemption lineage cost

        uint256 ethSid = _composeEthPage();
        uint256 balanceSid = _composeBalancePage();

        (, uint256 costE,) = core.statementInfo(ethSid);
        (, uint256 costX,) = core.statementInfo(balanceSid);
        // the eth lineage records the dropped eth bid, the redemption lineage its score-scaled backstop: two different cost
        // bases, where decision 90 scaled each statement by its own cost
        assertTrue(costX != costE, "the two lineages record different cost bases");

        _setRefScore(MIN_REF_SCORE); // the smallest refScore, so the rate term binds for both lineages

        uint256 p = core.floorRate();
        uint256 re = core.ratingOf(ethSid);
        uint256 rx = core.ratingOf(balanceSid);

        // the reference is the rate term for both, cost absent
        assertEq(ctl.referenceOf(ethSid), FullMath.mulDiv(p, re, MIN_REF_SCORE), "the eth lineage references the rate term");
        assertEq(ctl.referenceOf(balanceSid), FullMath.mulDiv(p, rx, MIN_REF_SCORE), "the redemption lineage references the rate term");
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

    // promise: SPEC 1 the reference follows the floor rate at the call
    /// the reference moves with the floor rate at the call. raising the stored rate raises the reference and the curve
    /// price in step, and `atFloor` stays an age decision through the move
    function test_referenceMovesWithTheFloorRate() public {
        uint256 sid = _composeOnce().sid;
        _setRefScore(MIN_REF_SCORE); // the rate term binds
        uint256 rating = core.ratingOf(sid);

        uint256 p1 = core.floorRate();
        assertEq(ctl.referenceOf(sid), FullMath.mulDiv(p1, rating, MIN_REF_SCORE), "the reference is the rate term at the current floor rate");
        uint256 price1 = ctl.priceOf(sid);
        bool floor1 = ctl.atFloor(sid);

        _liftRateCap();
        vm.prank(owner);
        core.setRate(p1 * 2);
        uint256 p2 = core.floorRate();
        assertGt(p2, p1, "the floor rate moved up");

        assertEq(ctl.referenceOf(sid), FullMath.mulDiv(p2, rating, MIN_REF_SCORE), "the reference followed the floor rate at the call");
        assertEq(ctl.priceOf(sid), price1 * p2 / p1, "the curve price followed the reference");
        assertEq(ctl.atFloor(sid), floor1, "atFloor is an age decision, unchanged by the floor rate move");
    }

    // ------------------------------------------------------------------ curve, floor and eligibility

    // ------------------------------------------------------------------ anchor

    // ------------------------------------------------------------------ core hard floor and value floor

    // promise: SPEC 1 the Core hard floor bounds a sale whatever the controller quotes (inv 3)
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
}
