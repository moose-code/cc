// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {ValueBase} from "../ValueMode.t.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Settings, POINT_UNIT, RATE_SCORE} from "../../src/interfaces/Interfaces.sol";

/// audit of main 84ea170: executable reproductions of three suspected contract defects. each test asserts the rule the
/// spec or the decision log states, so a failing test is the defect and a passing test after a fix is its closure.
contract AuditFindingsTest is Fixture {
    function _setPaused(bool v) internal {
        vm.prank(owner);
        core.setPaused(v);
    }

    /// finding A (decision 143 claims the bounds keep the post fill rate above zero): with `dropFloorBps` 1 the bucket
    /// floor is `minuteStartRate / 10_000`, which is 0 under 10_000 wei, and `_drop` rounds a price of a few wei to 0.
    /// `_climb` never climbs from a stored rate of 0, so the bid is dead until `setRate`
    // promise: SPEC 1 a credit whose bid the pot covers can be sold to the engine; the rate never reaches an absorbing zero
    function test_rateCanReachZeroAndNeverClimbsBack() public {
        _addToPot(1 ether);
        vm.prank(owner);
        core.setRate(2);
        uint256[] memory ids = _credits(seller, 3);
        for (uint256 i; i < ids.length; ++i) {
            _mockScore(ids[i], 8_000_000);
        }
        vm.startPrank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(core.rateAtCheckpoint(), 1, "first fill at 2 wei rounds the rate to 1 wei");
        core.sellForEth(_one(ids[1]));
        assertEq(core.rateAtCheckpoint(), 0, "second fill rounds the rate to 0");
        vm.stopPrank();

        _warp(7 days);
        _addToPot(1 ether);
        assertGt(core.ethPrice(), 0, "a funded pot climbs the price state after a week");
        assertGt(core.ethRate(), 0, "the bid reopens after a week");
        vm.startPrank(seller);
        core.sellForEth(_one(ids[2]));
        vm.stopPrank();
    }

    /// the recovery the owner has: `setRate` restates the rate and the bid reopens
    // promise: setRate restates a zero rate
    function test_setRateRecoversAZeroRate() public {
        _addToPot(1 ether);
        vm.prank(owner);
        core.setRate(2);
        uint256[] memory ids = _credits(seller, 2);
        _mockScore(ids[0], 8_000_000);
        _mockScore(ids[1], 8_000_000);
        vm.startPrank(seller);
        core.sellForEth(_one(ids[0]));
        core.sellForEth(_one(ids[1]));
        vm.stopPrank();
        assertEq(core.rateAtCheckpoint(), 0);
        _warp(1 days);
        assertEq(core.ethRate(), 0, "the bid reads zero a day later");
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        assertGt(core.ethRate(), 0, "setRate reopens the bid");
    }

    /// finding B (decision 178: neither bid clock earns paused time). the unpause shifts `climbRestartTime` but not the
    /// eth `lastFillTime`; the idle loosening anchors on the later of the two, so when the last fill is later than the
    /// last funded restart the shifted restart overtakes it and the ceiling gains paused time. the control run and the
    /// paused run have the same unpaused idle time after the fill, so the spec says the price state must be equal
    // promise: SPEC 1 both bid clocks exclude paused time and resume from the same level
    function test_pauseDoesNotAddIdleLooseningSteps() public {
        _liftRateCap();
        _addToPot(5 ether);
        // the funded restart is the funding time; the fill one hour later is the later anchor
        _warp(1 hours);
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        _warp(30 minutes);

        uint256 snap = vm.snapshotState();
        _warp(20 minutes);
        uint256 control = core.ethPrice();
        vm.revertToState(snap);

        _setPaused(true);
        _warp(3 hours);
        _setPaused(false);
        _warp(20 minutes);
        uint256 afterPause = core.ethPrice();
        emit log_named_uint("price state, no pause, 50 min idle", control);
        emit log_named_uint("price state, 3 h pause, 50 min idle", afterPause);
        assertEq(afterPause, control, "paused time added idle loosening steps to the ceiling");
    }
}

/// finding C (decision 159 C02: an unusable quote "degrades pricing instead of halting"). in value mode the fallback bid
/// is the stored `rateAtCheckpoint`, which no fill changes and which does not follow the pool, so during a quote outage
/// the engine pays a fixed pre outage price whatever the token does
contract AuditValueFallbackTest is ValueBase {
    // promise: SPEC 4 value mode prices the eth bid off the protected value of the balance token
    function test_quoteOutageFreezesTheBidThroughATokenCrash() public {
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.spendCapBps = 9_999;
        _setSettings(s);
        // a checkpoint in value mode stores the last good value rate
        _addToPot(5 ether);
        (, bool ok) = ctl.valuePerPoint(false);
        assertTrue(ok, "the quote is usable before the outage");
        uint256 healthy = core.ethRate();
        assertGt(healthy, 0);

        // the outage: the reference lapses past referenceMaxStale with no refresh
        _warp(1 days + 1);
        (, ok) = ctl.valuePerPoint(false);
        assertFalse(ok, "the quote is unusable");
        // the token loses half its value while the quote is out
        uint256 spotAfter = _swapSpot(-5000);
        uint256 frozen = core.ethRate();
        // the bid a usable quote would pay at the crashed spot: shared bps times the value of one point at the spot
        uint256 liveValue = core.sharedRate() * (POINT_UNIT * UNIT * spotAfter / 1e18) * 100 / 10_000;
        emit log_named_uint("bid before the outage", healthy);
        emit log_named_uint("bid during the outage after a 50 percent crash", frozen);
        emit log_named_uint("bid a live quote would pay at the crashed spot", liveValue);

        // fills during the outage: every credit is paid the same frozen rate
        uint256[] memory ids = _credits(seller, 3);
        uint256 stored = core.rateAtCheckpoint();
        uint256[3] memory paid;
        for (uint256 i; i < 3; ++i) {
            uint256 before = seller.balance;
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            paid[i] = seller.balance - before;
            assertEq(paid[i], frozen * _scoreOf(ids[i]) / RATE_SCORE, "paid at the frozen rate");
        }
        assertEq(core.rateAtCheckpoint(), stored, "no fill moves the fallback rate");
        assertLe(frozen, liveValue * 11_000 / 10_000, "the outage bid follows the token's value");
    }
}
