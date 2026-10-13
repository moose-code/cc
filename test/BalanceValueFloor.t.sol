// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet, ICreditScore} from "../src/interfaces/Interfaces.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// the pool term of `valueOf` (decisions 104 and 105). `valueOf(points)` is the larger of the rate term
/// `floorRate * points / refScore` and the redeemable value of `points * unitPerPoint` balance token base units in eth,
/// read from the balance token / native eth uniswap v4 pool with the unit read from the module in the call. the
/// reference of a statement and the floor of a credit price are built on it
contract BalanceValueFloorTest is Fixture {
    /// initializes a native eth / balance token pool at sqrt price `sp` and points the controller at it. native eth is
    /// currency0
    function _initAndSet(uint160 sp, uint24 fee, int24 tickSpacing) private {
        PoolKey memory vk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PM.initialize(vk, sp);
        _setKey(address(0), address(xt), fee, tickSpacing);
    }

    function _setKey(address c0, address c1, uint24 fee, int24 tickSpacing) private {
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(c0),
            currency1: IControllerV1.Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        vm.prank(owner);
        ctl.setBalancePoolKey(k);
    }

    /// the pool term in wei of `points` at sqrt price `sp` and unit `unit`, native eth currency0
    function _pool(uint256 points, uint256 unit, uint160 sp) private pure returns (uint256) {
        uint256 q = FixedPoint96.Q96;
        return FullMath.mulDiv(FullMath.mulDiv(points * unit, q, sp), q, sp);
    }

    /// the rate term in wei of `points`
    function _rate(uint256 points) private view returns (uint256) {
        return FullMath.mulDiv(core.floorRate(), points, ctl.refScore());
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _lowSqrtPrice() private pure returns (uint160) {
        // a small sqrt price makes the balance token expensive in eth, so the pool term is large
        return uint160(FixedPoint96.Q96 / 1000);
    }

    function _highSqrtPrice() private pure returns (uint160) {
        // a large sqrt price makes the balance token cheap in eth, so the pool term is small but nonzero
        return uint160(FixedPoint96.Q96 * 1000);
    }

    function _score(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    function test_poolTermBindsAboveTheRateTerm() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint160 sp = _lowSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 rating = core.ratingOf(sid);
        uint256 pool = _pool(rating, UNIT, sp);
        assertGt(pool, _rate(rating), "the pool term is above the rate term");
        assertEq(ctl.valueOf(rating), pool, "valueOf is the pool term");
        (, uint256 cost,) = core.statementInfo(sid);
        assertEq(ctl.referenceOf(sid), _max(cost, pool), "the reference carries the pool term");
        // the opening ask is the start of the curve on the reference
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * ctl.startBps() / 10_000, "the curve is on the reference");
    }

    /// the pool term follows the unit the module reports now, and a failing read gives pool term 0 so the rate term and
    /// the cost bound the reference
    function test_poolTermReadsTheLiveUnit() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint160 sp = _lowSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 rating = core.ratingOf(sid);
        assertEq(ctl.valueOf(rating), _pool(rating, UNIT, sp), "the unit at the set");
        mod.setUnitPerPoint(UNIT * 2);
        assertEq(ctl.valueOf(rating), _pool(rating, UNIT * 2, sp), "a higher unit raises the term");
        mod.setUnitPerPoint(UNIT / 2);
        assertEq(ctl.valueOf(rating), _pool(rating, UNIT / 2, sp), "a lower unit lowers the term");
        mod.setRevertUnit(true);
        assertEq(ctl.valueOf(rating), _rate(rating), "a failing read leaves the rate term");
        mod.setRevertUnit(false);
        mod.setUnitPerPoint(0);
        assertEq(ctl.valueOf(rating), _rate(rating), "a zero unit leaves the rate term");
    }

    function test_buyPaysTheGrossPriceAndTheAnchorStaysOnTheCurve() public {
        _enterPhase2();
        vm.prank(owner);
        ctl.setAnchorMinCost(0);
        uint256 sid = _composeOnce().sid;
        _initAndSet(_lowSqrtPrice(), 3000, 60);
        uint256 price = ctl.priceOf(sid);
        uint256 gross = ctl.grossPriceOf(sid);
        assertEq(gross, price + price * ctl.royaltyBps() / 10_000, "the gross price adds the royalty");
        address buyer = _user("buyer");
        vm.deal(buyer, gross);
        vm.prank(buyer);
        ctl.buy{value: gross}(sid);
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held, "the statement left the core");
        assertEq(ctl.royaltyOwed(), gross - price, "the royalty is owed");
        // the opening curve is 150 percent of the reference: the anchor moves to the mean of 10_000 and 15_000
        assertEq(ctl.anchorBps(), 12_500, "the anchor moved on the curve price");
    }

    function test_lowPoolPriceLeavesTheRateTerm() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint160 sp = _highSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 rating = core.ratingOf(sid);
        uint256 pool = _pool(rating, UNIT, sp);
        assertGt(pool, 0, "the pool term is nonzero");
        assertLt(pool, _rate(rating), "the pool term is below the rate term");
        assertEq(ctl.valueOf(rating), _rate(rating), "valueOf stays on the rate term, the pool never lowers it");
        (, uint256 cost,) = core.statementInfo(sid);
        assertGe(ctl.referenceOf(sid), cost, "the reference is never below the cost");
    }

    function test_keyUnsetGivesTheRateTerm() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        assertFalse(ctl.balancePoolKeySet(), "no pool key at launch");
        uint256 rating = core.ratingOf(sid);
        assertEq(ctl.valueOf(rating), _rate(rating), "valueOf is the rate term");
        assertEq(ctl.pointRate(), core.floorRate() / ctl.refScore(), "the point rate");
    }

    function test_noModuleGivesTheRateTerm() public {
        uint256 rating = 1_000_000;
        assertEq(ctl.valueOf(rating), _rate(rating), "no module, no pool term");
    }

    /// a credit price rests at `max(cost, valueOf(score)) * creditFloorBps`, so the pool term lifts the credit floor and
    /// never lowers it below the cost
    function test_creditFloorCarriesThePoolTerm() public {
        _enterPhase2();
        uint256 id = _fillEthPile(1)[0];
        (, uint256 cost, uint64 acquiredAt) = core.creditInfo(id);
        uint256 score = _score(id);
        vm.warp(acquiredAt + ctl.creditWindow());
        uint256 base = ctl.creditPrice(id);
        assertEq(base, _max(cost, _rate(score)) * ctl.creditFloorBps() / 10_000, "no pool key: the rate term and the cost");
        uint160 sp = _lowSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 pool = _pool(score, UNIT, sp);
        assertGt(pool, cost, "the pool term is above the cost");
        assertEq(ctl.creditPrice(id), pool * ctl.creditFloorBps() / 10_000, "the pool term lifts the credit floor");
        mod.setRevertUnit(true);
        assertEq(ctl.creditPrice(id), base, "a failing unit read leaves the floor on the cost and the rate term");
        assertGe(ctl.creditPrice(id), cost * ctl.creditFloorBps() / 10_000, "never below the cost floor");
    }

    function test_uninitializedPoolRejected() public {
        _enterPhase2();
        // a pool that was never initialized reads a zero sqrt price: the setter refuses it so the floor is never off
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(k);
        assertFalse(ctl.balancePoolKeySet(), "the key stays unset");
    }

    function test_setterTakesNativeEthCurrency0Only() public {
        _enterPhase2();
        // native eth currency0, balance token currency1, on an initialized pool: accepted
        _initAndSet(_highSqrtPrice(), 3000, 60);
        assertTrue(ctl.balancePoolKeySet(), "the native eth currency0 order is accepted");
        // balance token currency0, native eth currency1 cannot be a native eth pool and is refused
        IControllerV1.PoolKey memory reverseKey = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(xt)),
            currency1: IControllerV1.Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(reverseKey);
    }

    function test_setterRejectsPairsWithoutTheTokenAndNativeEth() public {
        _enterPhase2();
        address other = address(0xBEEF);
        vm.startPrank(owner);
        IControllerV1.PoolKey memory noEth = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(xt)),
            currency1: IControllerV1.Currency.wrap(other),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(noEth);
        IControllerV1.PoolKey memory noToken = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(other),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(noToken);
        vm.stopPrank();
    }

    function test_setterIsOwnerOnly() public {
        _enterPhase2();
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setBalancePoolKey(k);
    }

    function test_extremeSqrtPricesDoNotRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 rating = core.ratingOf(sid);
        // the minimum sqrt price: the balance token is as expensive as the pool allows, the term is huge but finite
        uint160 lo = TickMath.MIN_SQRT_PRICE;
        _initAndSet(lo, 3000, 60);
        assertEq(ctl.valueOf(rating), _max(_rate(rating), _pool(rating, UNIT, lo)), "min sqrt price prices without reverting");
        // the maximum sqrt price: the balance token is as cheap as the pool allows, the term rounds to zero
        uint160 hi = TickMath.MAX_SQRT_PRICE - 1;
        _initAndSet(hi, 500, 10);
        assertEq(ctl.valueOf(rating), _max(_rate(rating), _pool(rating, UNIT, hi)), "max sqrt price prices without reverting");
    }

    function test_pauseFreezesTheCurveWhileTheReferenceStaysLive() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _initAndSet(_lowSqrtPrice(), 3000, 60);
        assertFalse(ctl.atFloor(sid), "the opening curve is above the floor");
        uint256 priceBefore = ctl.priceOf(sid);
        vm.prank(owner);
        ctl.setPaused(true);
        _warp(300 hours);
        assertFalse(ctl.atFloor(sid), "the curve is frozen by the pause, still above the floor");
        assertEq(ctl.priceOf(sid), priceBefore, "the reference is unchanged while nothing moved");
        // the owner names a module with twice the unit: the live reference doubles while the curve stays frozen
        MockBalanceModule mod2 = new MockBalanceModule(address(xt), UNIT * 2);
        _setBalanceModule(address(mod2));
        assertEq(ctl.priceOf(sid), priceBefore * 2, "the reference tracks the live unit during a pause");
        assertFalse(ctl.atFloor(sid), "the curve is still frozen");
    }
}
