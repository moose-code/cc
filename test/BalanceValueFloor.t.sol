// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE, Mainnet, ICreditScore} from "../src/interfaces/Interfaces.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {MockBalanceModule} from "./standins/MockBalanceModule.sol";
import {MockBalanceToken} from "./standins/MockBalanceToken.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// with value mode off `valueOf(points)` is the rate term `floorRate * points / refScore`, whether or not a balance pool
/// key is set. the reference of a statement and the floor of a credit price are built on it. ported to the live fork:
/// the live Core carries value mode off, so pointing the controller at the live eth/BALANCE pool must not move valueOf,
/// the reference or the credit floor. the unit-manipulation sub-checks exercise a hostile module (not a live contract),
/// so they select a `MockBalanceModule` on the live Core: the live treasury's unit is a constant that cannot revert
contract BalanceValueFloorTest is LiveFixture {
    /// the rate term in wei of `points`
    function _rate(uint256 points) private view returns (uint256) {
        return FullMath.mulDiv(core.floorRate(), points, RATE_SCORE);
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _score(uint256 id) private view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    /// selects a fresh `MockBalanceModule` (on a fresh `MockBalanceToken`) as the live Core's balance module, so the
    /// unit read can be made to change or revert. value mode is off, so valueOf never reads the module; the module is
    /// only the subject that proves it
    function _selectMockModule() private returns (MockBalanceModule m) {
        MockBalanceToken mockXt = new MockBalanceToken("Balance Token", "XT");
        m = new MockBalanceModule(address(mockXt), UNIT);
        mockXt.mint(address(m), 1e24);
        vm.prank(owner);
        core.setBalanceModule(address(m));
    }

    // promise: with value mode off a pool key changes no value or reference
    function test_poolKeyDoesNotMoveValueOrReference() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 rating = core.ratingOf(sid);
        uint256 refBefore = ctl.referenceOf(sid);
        uint256 askBefore = ctl.priceOf(sid);
        _setLiveBalancePool();
        assertEq(ctl.valueOf(rating), _rate(rating), "valueOf is the rate term");
        (, uint256 cost,) = core.statementInfo(sid);
        assertEq(ctl.referenceOf(sid), _max(cost, _rate(rating)), "the reference is the cost or the rate term");
        assertEq(ctl.referenceOf(sid), refBefore, "the reference is unchanged by the key");
        assertEq(ctl.priceOf(sid), askBefore, "the ask is unchanged by the key");
    }

    // promise: with a pool key set, the unit read and an overflowing pool price leave valueOf and priceOf unchanged
    function test_poolKeyIgnoresTheUnitAndOverflow() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256 rating = core.ratingOf(sid);
        _setLiveBalancePool();
        MockBalanceModule mockMod = _selectMockModule();
        uint256 ask = ctl.priceOf(sid);
        mockMod.setUnitPerPoint(type(uint128).max);
        assertEq(ctl.valueOf(rating), _rate(rating), "an extreme unit leaves the rate term");
        mockMod.setUnitPerPoint(UNIT * 2);
        assertEq(ctl.valueOf(rating), _rate(rating), "a changed unit leaves the rate term");
        mockMod.setRevertUnit(true);
        assertEq(ctl.valueOf(rating), _rate(rating), "a failing unit read leaves the rate term");
        assertEq(ctl.priceOf(sid), ask, "priceOf is unchanged");
    }

    // promise: SPEC 1 no pool key gives the rate term only
    function test_keyUnsetGivesTheRateTerm() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        assertFalse(ctl.balancePoolKeySet(), "no pool key at launch");
        uint256 rating = core.ratingOf(sid);
        assertEq(ctl.valueOf(rating), _rate(rating), "valueOf is the rate term");
        assertEq(ctl.pointRate(), core.floorRate() / RATE_SCORE, "the point rate");
    }

    // promise: SPEC 8 the credit sale floor is max(cost, valueOf(score)) times floorMultBps, with or without a pool key
    function test_creditFloorIgnoresThePoolKey() public {
        _enterPhase2();
        uint256 id = _fillEthPile(1)[0];
        (, uint256 cost, uint64 acquiredAt) = core.creditInfo(id);
        uint256 score = _score(id);
        vm.warp(acquiredAt + ctl.creditWindow());
        uint256 base = ctl.creditPrice(id);
        assertEq(base, _max(cost, _rate(score)) * ctl.floorMultBps() / 10_000, "max of the cost and the rate term");
        _setLiveBalancePool();
        assertEq(ctl.creditPrice(id), base, "the pool key leaves the credit floor");
        MockBalanceModule mockMod = _selectMockModule();
        mockMod.setRevertUnit(true);
        assertEq(ctl.creditPrice(id), base, "a failing unit read leaves the credit floor");
    }

    // promise: INTEGRATION BadSetting on setBalancePoolKey
    function test_uninitializedPoolRejected() public {
        _enterPhase2();
        // a pool that was never initialized reads a zero sqrt price: the setter refuses it so the floor is never off
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(liveBalanceToken),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(k, 0);
        assertFalse(ctl.balancePoolKeySet(), "the key stays unset");
    }

    // promise: INTEGRATION BadSetting on setBalancePoolKey
    function test_setterRejectsPairsWithoutTheTokenAndNativeEth() public {
        _enterPhase2();
        address other = address(0xBEEF);
        vm.startPrank(owner);
        IControllerV1.PoolKey memory noEth = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(liveBalanceToken),
            currency1: IControllerV1.Currency.wrap(other),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(noEth, 0);
        IControllerV1.PoolKey memory noToken = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(other),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("balancePoolKey")));
        ctl.setBalancePoolKey(noToken, 0);
        vm.stopPrank();
    }

    // promise: INTEGRATION OnlyOwner on setBalancePoolKey
    function test_setterIsOwnerOnly() public {
        _enterPhase2();
        IControllerV1.PoolKey memory k = IControllerV1.PoolKey({
            currency0: IControllerV1.Currency.wrap(address(0)),
            currency1: IControllerV1.Currency.wrap(liveBalanceToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setBalancePoolKey(k, 0);
    }
}
