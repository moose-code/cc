// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {ValueBase} from "../ValueMode.t.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Settings, POINT_UNIT, RATE_SCORE} from "../../src/interfaces/Interfaces.sol";

/// audit of main 84ea170: executable reproductions of three contract defects, kept as the closure tests of decisions
/// 190, 193 and 194. each test asserts the rule the spec or the decision log states, so a failing test is the defect
/// and a passing test is its closure
contract AuditFindingsTest is Fixture {
    function _setPaused(bool v) internal {
        vm.prank(owner);
        core.setPaused(v);
    }

    /// finding A (decision 143 claims the bounds keep the post fill rate above zero): with `dropFloorBps` 1 the bucket
    /// floor is `minuteStartRate / 10_000`, which is 0 under 10_000 wei, and `_drop` rounded a price of a few wei to
    /// 0; `_climb` never climbs from a stored rate of 0. decision 194 floors the dropped rate at 1 wei
    // promise: SPEC 1 the price state never reaches an absorbing zero; a funded pot climbs it back from 1 wei
    function test_rateNeverReachesZeroAndClimbsBack() public {
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
        assertEq(core.rateAtCheckpoint(), 1, "a second fill holds the 1 wei floor");
        vm.stopPrank();

        _warp(7 days);
        _addToPot(1 ether);
        assertGt(core.ethPrice(), 1, "a funded pot climbs the price state above 1 wei after a week");
        assertGt(core.ethRate(), 0, "the bid is live after a week");
        vm.startPrank(seller);
        core.sellForEth(_one(ids[2]));
        vm.stopPrank();
    }

    /// the recovery the owner has: `setRate` restates the rate from the floor
    // promise: setRate restates a 1 wei rate
    function test_setRateRestatesTheFloorRate() public {
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
        assertEq(core.rateAtCheckpoint(), 1);
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        assertEq(core.rateAtCheckpoint(), OPEN_RATE, "setRate restates the rate");
        assertGt(core.ethRate(), 0, "the bid follows");
    }

    /// finding B (decision 178: neither bid clock earns paused time). the unpause shifted `climbRestartTime` but not
    /// the eth `lastFillTime`; the idle loosening anchors on the later of the two, so when the last fill was later than
    /// the last funded restart the shifted restart overtook it and the ceiling gained paused time. decision 194 shifts
    /// the fill time with the other clocks, so the control run and the paused run read the same price state
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

/// finding C (decision 159 C02 priced the eth bid at the stored `rateAtCheckpoint` during a quote outage, a price no
/// fill changed and that did not follow the token). decision 190: an unusable quote halts the eth purchase doors and
/// the views read 0; a usable quote takes the live pool spot on the side that favors the engine
contract AuditValueFallbackTest is ValueBase {
    function _valueModeOn() internal {
        Settings memory s = core.settings();
        s.valueModeOn = true;
        s.spendCapBps = 9_999;
        _setSettings(s);
    }

    /// a fresh block with no refresh due: the quote's sample is the seed spot, the live spot is whatever the pool reads
    function _freshBlock() internal {
        vm.roll(block.number + 1);
    }

    function _spotNow() internal view returns (uint256 spot) {
        (spot,) = ctl.spotPrice();
    }

    // promise: SPEC 4 value mode prices the eth bid off the protected value of the balance token; without a quote the
    // eth purchase doors refuse and the views read 0 (decision 190)
    function test_quoteOutageHaltsTheEthBidAndTheDoorsRefuse() public {
        _valueModeOn();
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
        _swapSpot(-5000);
        assertEq(core.ethRate(), 0, "the bid reads 0 during the outage");
        assertEq(core.ethPrice(), 0, "the price state reads 0 during the outage");
        uint256[] memory ids = _credits(seller, 2);
        assertEq(core.bidOf(ids[0]), 0, "bidOf reads 0 during the outage");
        vm.prank(seller);
        vm.expectRevert(ICore.NoQuote.selector);
        core.sellForEth(_one(ids[0]));
        // adopt in value mode refuses too: it would book a 1 wei basis
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[1]);
        vm.expectRevert(ICore.NoQuote.selector);
        core.adopt(_one(ids[1]));

        // the reference recovers with a refresh: the bid follows the crashed token, not the pre outage rate
        _freshBlock();
        assertTrue(ctl.refreshReference(), "the refresh runs");
        _freshBlock();
        uint256 recovered = core.ethRate();
        assertGt(recovered, 0, "the bid is live again");
        assertLt(recovered, healthy * 6_000 / 10_000, "the recovered bid follows the crash, within the band");
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
    }

    // promise: decision 190 a same block crash of the live spot lowers what the engine pays at once, and the fill pays
    // the view
    function test_liveCrashLowersTheEthBidAtOnce() public {
        _valueModeOn();
        _addToPot(5 ether);
        _freshBlock();
        uint256 before = core.ethRate();
        uint256 spotBefore = _spotNow();
        uint256 spotAfter = _swapSpot(-3_000);
        uint256 after_ = core.ethRate();
        assertApproxEqRel(after_, before * spotAfter / spotBefore, 2e16, "the bid falls with the live spot");
        uint256[] memory ids = _credits(seller, 1);
        uint256 quoted = core.bidOf(ids[0]);
        uint256 bal = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(seller.balance - bal, quoted, "the fill pays the view");
    }

    // promise: decision 190 a same block pump of the live spot does not raise what the engine pays: the sample and
    // the band bound the bid
    function test_livePumpDoesNotRaiseTheEthBid() public {
        _valueModeOn();
        _addToPot(5 ether);
        _freshBlock();
        uint256 before = core.ethRate();
        _swapSpot(3_000);
        assertEq(core.ethRate(), before, "a pumped live spot leaves the bid");
        uint256[] memory ids = _credits(seller, 1);
        uint256 quoted = core.bidOf(ids[0]);
        uint256 bal = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(seller.balance - bal, quoted, "the fill pays the unchanged view");
    }

    // promise: decision 190 the controller's sale price takes the live spot on the engine's side: a pump raises the
    // credit ask at once, a crash leaves it at the sample
    function test_liveSpotMovesTheAskOnlyUp() public {
        _valueModeOn();
        _addToPot(5 ether);
        _freshBlock();
        uint256 points = 100;
        uint256 before = ctl.valueOf(points);
        _swapSpot(-3_000);
        assertEq(ctl.valueOf(points), before, "a crashed live spot leaves the sale value at the sample");
        uint256 spotBefore = _spotNow();
        uint256 spotAfter = _swapToSpot(spotBefore * 13_000 / 10_000 * 10_000 / 7_000);
        uint256 pumped = ctl.valueOf(points);
        assertGt(pumped, before, "a pumped live spot raises the sale value at once");
        assertApproxEqRel(pumped, before * spotAfter / (spotBefore * 10_000 / 7_000), 2e16, "by the live spot");
    }

    // promise: decision 190 the balance payout cap takes the live spot on the engine's side: a pump lowers the payout
    // at once and a crash never raises it
    function test_liveSpotNeverRaisesTheBalancePayout() public {
        _valueModeOn();
        _addToPot(5 ether);
        _freshBlock();
        uint256[] memory ids = _credits(seller, 1);
        uint256 before = core.balanceBidOf(ids[0]);
        assertGt(before, 0);
        _swapSpot(3_000);
        uint256 pumped = core.balanceBidOf(ids[0]);
        assertLt(pumped, before, "a pumped live spot lowers the payout cap at once");
        uint256 spotNow = _spotNow();
        _swapToSpot(spotNow * 5_000 / 10_000);
        assertLe(core.balanceBidOf(ids[0]), before, "a crashed live spot never raises the payout");
    }
}
