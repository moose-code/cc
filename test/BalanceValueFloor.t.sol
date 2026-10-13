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

    function _score(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    // promise: SPEC 1 the price reference is at least the redemption value read from the balance token pool (decision 87)
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

    // promise: SPEC 1 the unit is read live from the module (decision 103)
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

    // promise: SPEC 1 priceOf never reverts for a failed pool read
    /// an extreme unit with a tiny pool sqrt price overflows 256 bits in the second `mulDiv` of the pool pricing: the pool
    /// term is 0, `valueOf` answers the rate term and `priceOf` answers
    function test_poolTerm_overflowYieldsZeroAndNeverReverts() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _initAndSet(TickMath.MIN_SQRT_PRICE, 3000, 60);
        mod.setUnitPerPoint(type(uint128).max);
        uint256 rating = core.ratingOf(sid);
        assertEq(ctl.valueOf(rating), _rate(rating), "the overflowing pool term reads 0");
        assertGt(ctl.priceOf(sid), 0, "priceOf answers");
    }

    // promise: SPEC 1 no pool key gives the rate term only
    function test_keyUnsetGivesTheRateTerm() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        assertFalse(ctl.balancePoolKeySet(), "no pool key at launch");
        uint256 rating = core.ratingOf(sid);
        assertEq(ctl.valueOf(rating), _rate(rating), "valueOf is the rate term");
        assertEq(ctl.pointRate(), core.floorRate() / ctl.refScore(), "the point rate");
    }

    // promise: SPEC 1 the credit sale floor is max(cost, valueOf(score)) times creditFloorBps
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

    // promise: INTEGRATION BadSetting on setBalancePoolKey
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

    // promise: INTEGRATION BadSetting on setBalancePoolKey
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

    // promise: INTEGRATION OnlyOwner on setBalancePoolKey
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

}
