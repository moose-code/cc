// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SaleShapeBase} from "./Sale.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {CreditSale, Settings} from "../src/interfaces/Interfaces.sol";

/// the owner pause of the Core on the live fork: acquisition, composition and buybacks stop; statement age excludes
/// paused seconds, while fee booking, funding and redemption remain available
contract PauseTest is SaleShapeBase {
    address internal buyer = address(0xB0B);

    function _setPaused(bool v) internal {
        vm.prank(owner);
        core.setPaused(v);
    }

    // promise: SPEC 1 sales are unpaused at launch
    function test_launchValueIsUnpaused() public view {
        assertFalse(core.paused());
        assertEq(core.pausedSince(), 0);
        assertEq(core.pausedTotal(), 0);
    }

    // promise: INTEGRATION OnlyOwner on setPaused
    function test_setPaused_onlyTheLiveOwner() public {
        vm.prank(buyer);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setPaused(false);
        assertFalse(core.paused());

        address heir = address(0x4E12);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setPaused(true);
        vm.prank(heir);
        core.setPaused(true);
        assertTrue(core.paused(), "the new owner pauses");
    }

    // promise: INTEGRATION PausedSet is emitted on each change only
    function test_setPaused_eventAndNoOpRepeats() public {
        vm.expectEmit(address(core));
        emit ICore.PausedSet(true);
        _setPaused(true);
        assertTrue(core.paused());
        assertEq(core.pausedSince(), block.timestamp);

        vm.warp(block.timestamp + 100);
        vm.recordLogs();
        _setPaused(true);
        assertEq(vm.getRecordedLogs().length, 0, "pausing a paused core emits nothing");
        assertTrue(core.paused());
        assertEq(core.pausedSince(), block.timestamp - 100, "the repeat leaves the start of the pause");

        vm.expectEmit(address(core));
        emit ICore.PausedSet(false);
        _setPaused(false);
        assertFalse(core.paused());
        assertEq(core.pausedSince(), 0);
        assertEq(core.pausedTotal(), 100);

        vm.warp(block.timestamp + 100);
        vm.recordLogs();
        _setPaused(false);
        assertEq(vm.getRecordedLogs().length, 0, "resuming a running core emits nothing");
        assertFalse(core.paused());
        assertEq(core.pausedTotal(), 100, "the repeat leaves the total");
    }

    // promise: INTEGRATION Paused
    function test_buy_revertsWhilePausedAndWorksAfterResume() public {
        uint256 sid = _composeOnce().sid;
        _setPaused(true);
        uint256 price = ctl.priceOf(sid);
        assertGt(price, 0, "priceOf answers while paused");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(ICore.Paused.selector);
        ctl.buy{value: price}(sid);
        vm.prank(buyer);
        vm.expectRevert(ICore.Paused.selector);
        ctl.buy{value: 10 ether}(sid);
        assertTrue(_held(sid), "the statement is still held");
        assertEq(buyer.balance, 10 ether, "nothing was taken");

        _setPaused(false);
        _pay(buyer, sid, ctl.priceOf(sid));
        assertEq(STATEMENTS.ownerOf(sid), buyer, "sold after the resume");
    }

    // promise: INTEGRATION Paused follows OnlyController on sellTo and sellCreditTo
    /// the pause check follows the controller check and precedes every other check of both sale doors
    function test_sellDoors_pausedRevertsAfterTheControllerCheck() public {
        _setPaused(true);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo(123_456_789, buyer);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellCreditTo(123_456_789, buyer);
        vm.startPrank(address(ctl));
        vm.expectRevert(ICore.Paused.selector);
        core.sellTo(123_456_789, buyer);
        vm.expectRevert(ICore.Paused.selector);
        core.sellCreditTo(123_456_789, buyer);
        vm.stopPrank();
        _setPaused(false);
        vm.startPrank(address(ctl));
        vm.expectRevert(ICore.NotForSale.selector);
        core.sellTo(123_456_789, buyer);
        vm.stopPrank();
    }

    // promise: SPEC 1 the age a price falls with excludes every paused second
    /// a statement 2 hours into its 4 hour fall is at hour 2 of the fall after a pause of any length, and the fall goes on
    function testFuzz_priceIsFrozenAndResumesAtTheSameAge(uint32 length) public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 2 * H);
        uint256 before = ctl.priceOf(sid);
        assertEq(before, _launch(cost, 2 * H), "hour 2 of the launch curve");
        _setPaused(true);
        assertEq(ctl.priceOf(sid), before, "the price at the pause");
        vm.warp(block.timestamp + length);
        assertEq(ctl.priceOf(sid), before, "the price stays through the pause");
        _setPaused(false);
        assertEq(ctl.priceOf(sid), before, "the price at the resume");
        vm.warp(block.timestamp + 1 hours);
        assertEq(ctl.priceOf(sid), _launch(cost, 3 * H), "hour 3 an hour after the resume");
        assertLt(ctl.priceOf(sid), before);
    }

    // promise: an owner pause stops composition without changing a held statement's age
    function test_compose_stopsWhilePausedAndResumesWithTheSameAge() public {
        uint256 first = _composeOnce().sid;
        _age(first, 3 * H);
        _setPaused(true);
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        vm.expectRevert(ICore.Paused.selector);
        core.compose();
        vm.prank(keeper);
        vm.expectRevert(ICore.Paused.selector);
        core.compose(0);
        assertEq(STATEMENTS.supply(), supply);
        vm.warp(block.timestamp + 5 days);
        assertEq(ctl.priceOf(first), _launch(_cost(first), 3 * H), "the older statement keeps its age");
        _setPaused(false);
        uint256 second = _another();
        uint256 cost = _cost(second);
        assertEq(ctl.priceOf(second), _launch(cost, 0), "age zero at the resume");
        vm.warp(block.timestamp + 10 * H);
        assertEq(ctl.priceOf(second), _launch(cost, 10 * H), "it ages from the resume");
        assertEq(ctl.priceOf(first), _launch(_cost(first), 13 * H), "the older statement continues");
    }

    // promise: SPEC 1 the anchor decays with wall time in a pause
    /// the anchor keeps its time decay in a pause, and the price follows it with the age held
    function test_anchorDecaysWhilePaused() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _anchor(30_000);
        _setPaused(true);
        uint256 frozenAge = block.timestamp - _composedAt(sid);
        assertEq(ctl.anchorBps(), 30_000);
        vm.warp(block.timestamp + ctl.anchorHalfLife());
        assertEq(ctl.anchorBps(), 20_000, "the excess over 10_000 halved in the pause");
        assertEq(
            ctl.priceOf(sid),
            _curve(cost, ctl.startBps(), core.settings().saleFloorBps, ctl.decayHours(), frozenAge),
            "the start follows the anchor, the age is held"
        );
        _setPaused(false);
        assertEq(ctl.anchorBps(), 20_000);
    }

    // promise: SPEC 1 the credit window clock keeps running in a pause
    /// the credit window runs in wall time: a pause does not extend the time a credit must sit before compose
    function test_creditWindowRunsInWallTimeWhilePaused() public {
        CreditSale memory c = _creditSale();
        c.saleOn = true;
        c.window = 1 hours;
        vm.prank(owner);
        ctl.setCredit(c);
        uint64 acquiredAt = uint64(block.timestamp);
        assertFalse(ctl.pastWindow(acquiredAt));
        _setPaused(true);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(ctl.pastWindow(acquiredAt), "the window passed during the pause");
    }

    // promise: an owner pause stops every intake route and buyback before they move assets
    function test_allIntakeAndBuybackDoorsStopWhilePaused() public {
        _setPaused(true);
        uint256 size = core.pileSize();
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForEth(ids);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForEth(ids, 0);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForBalance(ids);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForBalance(ids, 0);
        vm.expectRevert(ICore.Paused.selector);
        core.sellForBalance(ids, 0, address(0));
        vm.expectRevert(ICore.Paused.selector);
        core.buyListing(address(0), 0, "");
        vm.expectRevert(ICore.Paused.selector);
        core.adopt(ids);
        uint256[80] memory chosen;
        vm.expectRevert(ICore.Paused.selector);
        core.composeChosen(chosen, 0);
        vm.expectRevert(ICore.Paused.selector);
        core.buyback();
        assertEq(core.pileSize(), size);
        _setPaused(false);
        _fillEthPile(5);
        assertEq(core.pileSize(), size + 5);
    }

    // promise: paused time cannot raise the bid, including through funding and booking, and earned climb survives
    function test_bidClockFreezesAcrossPauseAndResumes() public {
        _liftRateCap();
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        core.fund{value: 1 ether}();
        vm.warp(block.timestamp + 11 minutes);
        uint256 earned = core.ethPrice();
        _setPaused(true);
        assertEq(core.ethPrice(), earned);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(buyer);
        core.fund{value: 1 ether}();
        core.book();
        assertEq(core.ethPrice(), earned, "fund and book cannot credit paused time");
        _setPaused(false);
        assertEq(core.ethPrice(), earned, "pre-pause climb survives the resume");
        vm.warp(block.timestamp + 11 minutes);
        assertGt(core.ethPrice(), earned, "climb resumes after the pause");
    }

    // promise: repeated pauses exclude only paused time and an owner rate reset remains usable during a pause
    function test_rateResetAndSecondPauseDoNotLoseEarnedBid() public {
        _liftRateCap();
        vm.deal(buyer, 3 ether);
        vm.prank(buyer);
        core.fund{value: 1 ether}();
        _setPaused(true);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        core.setRate(3e15);
        vm.warp(block.timestamp + 1 hours);
        assertEq(core.ethPrice(), 3e15, "a reset during pause does not climb");
        _setPaused(false);
        assertEq(core.ethPrice(), 3e15, "the reset survives resume");
        vm.warp(block.timestamp + 11 minutes);
        uint256 earned = core.ethPrice();
        assertGt(earned, 3e15);
        _setPaused(true);
        vm.warp(block.timestamp + 2 hours);
        _setPaused(false);
        assertEq(core.ethPrice(), earned, "a second pause preserves earned climb");
    }

    // promise: an owner half-life edit during a pause cannot consume paused hours from the remembered peak
    function test_halfLifeEditDuringPausePreservesBid() public {
        _liftRateCap();
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        core.fund{value: 1 ether}();
        vm.warp(block.timestamp + 11 minutes);
        uint256 earned = core.ethPrice();
        _setPaused(true);
        vm.warp(block.timestamp + 6 hours);
        Settings memory s = core.settings();
        s.peakHalfLife += 1 hours;
        _setSettings(s);
        assertEq(core.ethPrice(), earned, "settings edit cannot decay the peak through a pause");
        _setPaused(false);
        assertEq(core.ethPrice(), earned, "the remembered bid survives resume");
    }

    // promise: pausing intake does not take away an eligible holder's redemption or the public fee and funding doors
    function test_redemptionAndFeeIntakeRemainLiveWhilePaused() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _makeEligible(sid);
        _setPaused(true);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        core.fund{value: 0.1 ether}();
        core.book();
        core.redeemStatement(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(mod));
    }
}

/// the pause clock against an independent model on the real Core: statements composed before, during, between and after
/// pauses, at the boundaries too (a step of 0 seconds is common). the model counts the overlap pause by pause
contract PauseClockTest is SaleShapeBase {
    /// the seconds of [from, to] inside the pauses `ws[i]` to `we[i]` (`we[i]` zero: still open, counted to `to`)
    function _overlap(uint256[] memory ws, uint256[] memory we, uint256 n, uint256 from, uint256 to)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i; i < n; ++i) {
            uint256 s = ws[i] > from ? ws[i] : from;
            uint256 e = we[i] == 0 || we[i] > to ? to : we[i];
            if (e > s) total += e - s;
        }
    }

    /// the age and the price of every statement composed so far equal the wall time minus the paused seconds
    function _checkAll(uint256[] memory sids, uint256 ns, uint256[] memory ws, uint256[] memory we, uint256 nw)
        internal
        view
    {
        for (uint256 j; j < ns; ++j) {
            uint256 at = _composedAt(sids[j]);
            uint256 age = block.timestamp - at - _overlap(ws, we, nw, at, block.timestamp);
            assertEq(core.statementAge(sids[j]), age, "the age is wall time minus the paused seconds");
            // the curve prices on the statement reference, max(valueOf(rating), cost); valueOf tracks the bid floor
            // rate and can exceed the cost basis
            uint256 ref = ctl.referenceOf(sids[j]);
            assertEq(
                ctl.priceOf(sids[j]),
                _curve(ref, ctl.startBps(), core.settings().saleFloorBps, ctl.decayHours(), age),
                "the price is the curve at that age"
            );
        }
    }

    // promise: SPEC 1 statementAge is wall time minus paused time
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_ageIsWallTimeMinusPausedTime(uint256 seed) public {
        _ageRun(seed);
    }

    // promise: SPEC 1 statementAge is wall time minus paused time
    /// the fuzz counterexample from the 6d099486 candidate run: age clock correct, the price check uses the statement
    /// reference, not its cost
    function test_ageAtSeed17050() public {
        _ageRun(17050);
    }

    function _ageRun(uint256 seed) internal {
        uint256[] memory sids = new uint256[](3);
        uint256[] memory ws = new uint256[](16);
        uint256[] memory we = new uint256[](16);
        uint256 ns;
        uint256 nw;
        bool isPaused;
        sids[ns++] = _composeOnce().sid;
        for (uint256 i; i < 14; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + ((h >> 64) % 4 == 0 ? 0 : h % 20_001));
            uint256 op = (h >> 32) % 4;
            if (op < 2) {
                isPaused = !isPaused;
                vm.prank(owner);
                core.setPaused(isPaused);
                if (isPaused) {
                    ws[nw] = block.timestamp;
                    we[nw] = 0;
                    ++nw;
                } else {
                    we[nw - 1] = block.timestamp;
                }
            } else if (op == 2 && ns < 3 && !isPaused) {
                sids[ns++] = _another();
            } else {
                vm.prank(owner);
                core.setPaused(isPaused);
            }
            assertEq(core.paused(), isPaused);
            _checkAll(sids, ns, ws, we, nw);
        }
    }

    // promise: SPEC 1 the pause clock is O(1)
    /// the read cost of the age does not depend on the number of pauses
    function test_gas_ageReadIsConstantAfterManyPauses() public {
        uint256 sid = _composeOnce().sid;
        uint256 n = 200;
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 100);
            vm.prank(owner);
            core.setPaused(true);
            vm.warp(block.timestamp + 100);
            vm.prank(owner);
            core.setPaused(false);
        }
        vm.cool(address(core));
        uint256 g = gasleft();
        uint256 age = core.statementAge(sid);
        uint256 used = g - gasleft();
        emit log_named_uint("statementAge gas, 200 closed pauses, cold", used);
        assertEq(age, block.timestamp - _composedAt(sid) - n * 100);
        assertLt(used, 15_000);
    }
}
