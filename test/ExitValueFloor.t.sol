// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Mainnet} from "../src/interfaces/Interfaces.sol";
import {MockExitModule} from "./standins/MockExitModule.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// the redeemable value floor of the sale controller (decision 87). the asking price is floored at a statement's
/// redeemable value in eth, read from the exit token / native eth uniswap v4 pool. the floor only raises the price:
/// `atCost`, redemption eligibility and the anchor stay on the curve
contract ExitValueFloorTest is Fixture {
    /// initializes a native eth / exit token pool at sqrt price `sp` and points the controller at it. native eth is
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
        ctl.setExitPoolKey(k);
    }

    /// the redeemable value in wei the controller computes for `sid` at sqrt price `sp`, native eth currency0
    function _value(uint256 sid, uint160 sp) private view returns (uint256) {
        uint256 owed = core.ratingOf(sid) * core.unitPerPoint();
        uint256 q = FixedPoint96.Q96;
        return FullMath.mulDiv(FullMath.mulDiv(owed, q, sp), q, sp);
    }

    function _lowSqrtPrice() private pure returns (uint160) {
        // a small sqrt price makes the exit token expensive in eth, so the value floor is large
        return uint160(FixedPoint96.Q96 / 1000);
    }

    function _highSqrtPrice() private pure returns (uint160) {
        // a large sqrt price makes the exit token cheap in eth, so the value floor is small but nonzero
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
        (bool held,,,) = core.statementInfo(sid);
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
        assertFalse(ctl.exitPoolKeySet(), "no pool key at launch");
        assertEq(ctl.priceOf(sid), curve, "the asking price is the curve");
    }

    function test_uninitializedPoolGivesTheCurve() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        // point at a pool that was never initialized: the sqrt price reads zero
        _setKey(address(0), address(xt), 500, 10);
        assertTrue(ctl.exitPoolKeySet(), "the key is set");
        assertEq(ctl.priceOf(sid), curve, "a zero pool read falls to the curve");
    }

    function test_setterAcceptsBothCurrencyOrders() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        // native eth currency0, exit token currency1 (the order a real native pool has)
        _setKey(address(0), address(xt), 3000, 60);
        assertTrue(ctl.exitPoolKeySet());
        assertEq(ctl.priceOf(sid), curve, "uninitialized pool: the ask is the curve");
        // exit token currency0, native eth currency1 (accepted for completeness; a native pool cannot sort this way)
        _setKey(address(xt), address(0), 3000, 60);
        assertEq(ctl.priceOf(sid), curve, "the reverse order is accepted and falls to the curve");
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
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("exitPoolKey")));
        ctl.setExitPoolKey(noEth);
        IControllerV1.PoolKey memory noToken = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(other),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("exitPoolKey")));
        ctl.setExitPoolKey(noToken);
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
        ctl.setExitPoolKey(k);
    }

    function test_extremeSqrtPricesDoNotRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 curve = ctl.priceOf(sid);
        // the minimum sqrt price: the exit token is as expensive as the pool allows, the floor is huge but finite
        uint160 lo = TickMath.MIN_SQRT_PRICE;
        _initAndSet(lo, 3000, 60);
        uint256 vLo = _value(sid, lo);
        assertEq(ctl.priceOf(sid), vLo > curve ? vLo : curve, "min sqrt price prices without reverting");
        // the maximum sqrt price: the exit token is as cheap as the pool allows, the floor rounds to zero
        uint160 hi = TickMath.MAX_SQRT_PRICE - 1;
        _initAndSet(hi, 500, 10);
        uint256 vHi = _value(sid, hi);
        assertEq(ctl.priceOf(sid), vHi > curve ? vHi : curve, "max sqrt price prices without reverting");
    }

    function test_pauseFreezesTheCurveWhileTheValueStaysLive() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _initAndSet(_lowSqrtPrice(), 3000, 60);
        assertFalse(ctl.atCost(sid), "the opening curve is above cost");
        uint256 priceBefore = ctl.priceOf(sid);
        vm.prank(owner);
        ctl.setPaused(true);
        _warp(300 hours);
        assertFalse(ctl.atCost(sid), "the curve is frozen by the pause, still above cost");
        assertEq(ctl.priceOf(sid), priceBefore, "the value floor is unchanged while nothing moved");
        // the owner raises the owed amount per point by naming a module with twice the unit: the live value floor
        // doubles while the curve stays frozen
        MockExitModule mod2 = new MockExitModule(address(xt), UNIT * 2);
        _setExitModule(address(mod2));
        assertEq(ctl.priceOf(sid), priceBefore * 2, "the value floor tracks the live unit during a pause");
        assertFalse(ctl.atCost(sid), "the curve is still frozen");
    }
}
