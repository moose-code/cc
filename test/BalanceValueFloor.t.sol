// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// the redeemable value floor of the sale controller (decision 87). the asking price is floored at a statement's
/// redeemable value in eth, read from the balance token / native eth uniswap v4 pool. the floor only raises the price:
/// `atFloor`, redemption eligibility and the anchor stay on the curve
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

    /// the redeemable value in wei the controller computes for `sid` at sqrt price `sp`, native eth currency0
    function _value(uint256 sid, uint160 sp) private view returns (uint256) {
        uint256 owed = core.ratingOf(sid) * core.unitPerPoint();
        uint256 q = FixedPoint96.Q96;
        return FullMath.mulDiv(FullMath.mulDiv(owed, q, sp), q, sp);
    }

    function _lowSqrtPrice() private pure returns (uint160) {
        // a small sqrt price makes the balance token expensive in eth, so the value floor is large
        return uint160(FixedPoint96.Q96 / 1000);
    }

    function _highSqrtPrice() private pure returns (uint160) {
        // a large sqrt price makes the balance token cheap in eth, so the value floor is small but nonzero
        return uint160(FixedPoint96.Q96 * 1000);
    }

    function test_valueFloorBindsAboveTheCurve() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        uint160 sp = _lowSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 value = _value(sid, sp);
        assertGt(value, curve, "the value floor is above the curve");
        assertEq(ctl.priceOf(sid), value, "the asking price is the value floor");
    }

    /// after the module lowers its rate the floor uses the live unit, and a failing live read gives value 0 so the
    /// curve is the asking price. a higher live unit leaves the floor at the stored unit
    function test_valueFloorUsesTheLowerOfStoredAndLiveUnit() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        uint160 sp = _lowSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 full = _value(sid, sp);
        assertEq(ctl.priceOf(sid), full, "the floor starts at the stored unit");
        mod.setUnitPerPoint(core.unitPerPoint() * 2);
        assertEq(ctl.priceOf(sid), full, "a higher live unit keeps the stored unit");
        mod.setUnitPerPoint(core.unitPerPoint() / 2);
        uint256 half = ctl.priceOf(sid);
        assertLt(half, full, "a lower live unit lowers the floor");
        assertGt(half, curve, "the lowered floor still binds above the curve");
        uint256 owed = core.ratingOf(sid) * (core.unitPerPoint() / 2);
        uint256 q = FixedPoint96.Q96;
        assertEq(half, FullMath.mulDiv(FullMath.mulDiv(owed, q, sp), q, sp), "the floor is the live unit's value");
        mod.setRevertUnit(true);
        assertEq(ctl.priceOf(sid), curve, "a failing live read leaves the curve");
    }

    function test_buyPaysTheValueFloorAndTheAnchorStaysOnTheCurve() public {
        _enterPhase2();
        vm.prank(owner);
        ctl.setAnchorMinCost(0);
        uint256 sid = _composeOnce().sid;
        _initAndSet(_lowSqrtPrice(), 3000, 60);
        uint256 price = ctl.priceOf(sid);
        address buyer = _user("buyer");
        vm.deal(buyer, price);
        vm.prank(buyer);
        ctl.buy{value: price}(sid);
        (bool held,,) = core.statementInfo(sid);
        assertFalse(held, "the statement left the core");
        // the opening curve is 150 percent of cost: the anchor moves to the mean of 10_000 and 15_000, not to the
        // far larger value floor in bps of cost
        assertEq(ctl.anchorBps(), 12_500, "the anchor moved on the curve price");
    }

    function test_lowPoolPriceLeavesTheAskOnTheCurve() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        uint160 sp = _highSqrtPrice();
        _initAndSet(sp, 3000, 60);
        uint256 value = _value(sid, sp);
        assertGt(value, 0, "the value floor is nonzero");
        assertLt(value, curve, "the value floor is below the curve");
        assertEq(ctl.priceOf(sid), curve, "the asking price stays on the curve, the floor never lowers it");
    }

    function test_keyUnsetGivesTheCurve() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        assertFalse(ctl.balancePoolKeySet(), "no pool key at launch");
        assertEq(ctl.priceOf(sid), curve, "the asking price is the curve");
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
        uint256 curve = ctl.priceOf(sid);
        // the minimum sqrt price: the balance token is as expensive as the pool allows, the floor is huge but finite
        uint160 lo = TickMath.MIN_SQRT_PRICE;
        _initAndSet(lo, 3000, 60);
        uint256 vLo = _value(sid, lo);
        assertEq(ctl.priceOf(sid), vLo > curve ? vLo : curve, "min sqrt price prices without reverting");
        // the maximum sqrt price: the balance token is as cheap as the pool allows, the floor rounds to zero
        uint160 hi = TickMath.MAX_SQRT_PRICE - 1;
        _initAndSet(hi, 500, 10);
        uint256 vHi = _value(sid, hi);
        assertEq(ctl.priceOf(sid), vHi > curve ? vHi : curve, "max sqrt price prices without reverting");
    }

    function test_pauseFreezesTheCurveWhileTheValueStaysLive() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _initAndSet(_lowSqrtPrice(), 3000, 60);
        assertFalse(ctl.atFloor(sid), "the opening curve is above cost");
        uint256 priceBefore = ctl.priceOf(sid);
        vm.prank(owner);
        core.setPaused(true);
        _warp(300 hours);
        assertFalse(ctl.atFloor(sid), "the curve is frozen by the pause, still above cost");
        assertEq(ctl.priceOf(sid), priceBefore, "the value floor is unchanged while nothing moved");
        // the owner raises the owed amount per point by naming a module with twice the unit: the live value floor
        // doubles while the curve stays frozen
        MockBalanceModule mod2 = new MockBalanceModule(address(xt), UNIT * 2);
        _setBalanceModule(address(mod2));
        assertEq(ctl.priceOf(sid), priceBefore * 2, "the value floor tracks the live unit during a pause");
        assertFalse(ctl.atFloor(sid), "the curve is still frozen");
    }
}
