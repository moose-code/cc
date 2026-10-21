// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./LiveFixture.sol";
import {Fixture} from "./Fixture.sol";
import {IControllerV1} from "../../src/interfaces/IControllerV1.sol";
import {Settings, Quote, RATE_SCORE, POINT_UNIT} from "../../src/interfaces/Interfaces.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TestLiquidityHelper} from "./TestLiquidityHelper.sol";

/// @notice the live Core counterpart of test/ValueMode.t.sol's ValueBase, for the value mode suites that bind the live
/// Core instead of a fresh fixture Core. ValueBase itself cannot be reused: it extends the fresh deploy Fixture and is
/// shared by the value mode unit suites, which stay on that Fixture. the pool mechanics are identical to ValueBase.
///
/// the value mode reference pool is a fresh native eth / mock balance token pool, not the live BALANCE pool: these
/// suites push the spot and add and remove liquidity at will, which the live BALANCE token cannot do (its ink rule
/// refuses a `deal`, and the live pool liquidity is foreign). the mock stands in only as the controller's quoted pool
/// asset; the live Core, its real Statements, Credits and the real coin pool carry everything else
abstract contract LiveValueBase is LiveFixture {
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
        // the merged LiveFixture overrides `_enterPhase2` to the live token treasury; the value mode suites here need a
        // mintable mock balance token and a pool they can push and drain, so call the Fixture stand in path explicitly
        // on the live Core (the balance module and pool are the controller's quoted asset, not the treasury payout)
        Fixture._enterPhase2();
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
        _setQuote(
            Quote({
                referenceRateBpsPerHour: 1_000,
                referenceStepBps: 500,
                tolBps: 450,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 0,
                minLiquidity: 1e18
            })
        );
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
        uint256 target = bps > 0 ? start * (10_000 + uint256(bps)) / 10_000 : start * (10_000 - uint256(-bps)) / 10_000;
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
        // age only eligibility (decision 155) is a ControllerV1 setter ControllerV2 dropped; in stage B the live
        // controller is V2 and carries it already, so the V1 call is skipped there
        if (!_liveStageB()) {
            vm.startPrank(owner);
            ctl.setAgeEligibilityOn(true);
            vm.stopPrank();
        }
    }

    /// the eth bid the value mode prices for 100 points at the shared rate `bps`: `bps * valuePerPoint(false) * 100 / 10_000`
    function _valueRate(uint256 bps) internal view returns (uint256) {
        (uint256 v,) = ctl.valuePerPoint(false);
        return bps * v * 100 / 10_000;
    }
}
