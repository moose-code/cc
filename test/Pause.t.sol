// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SaleShapeBase} from "./Sale.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {CreditSale} from "../src/interfaces/Interfaces.sol";

/// the owner pause of the Core on the live fork: `sellTo` and `sellCreditTo` revert `Paused`, so `buy` and `buyCredit`
/// refuse, `priceOf` answers, the age a statement's price falls with excludes every paused second, composing, the bids
/// and redemptions are unaffected
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
    /// a statement 20 hours into its fall is at hour 20 of the fall after a pause of any length, and the fall goes on
    function testFuzz_priceIsFrozenAndResumesAtTheSameAge(uint32 length) public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 6 * H);
        uint256 before = ctl.priceOf(sid);
        assertEq(before, _launch(cost, 6 * H), "hour 6 of the launch curve");
        _setPaused(true);
        assertEq(ctl.priceOf(sid), before, "the price at the pause");
        vm.warp(block.timestamp + length);
        assertEq(ctl.priceOf(sid), before, "the price stays through the pause");
        _setPaused(false);
        assertEq(ctl.priceOf(sid), before, "the price at the resume");
        vm.warp(block.timestamp + 1 hours);
        assertEq(ctl.priceOf(sid), _launch(cost, 7 * H), "hour 7 an hour after the resume");
        assertLt(ctl.priceOf(sid), before);
    }

    // promise: SPEC 1 composing runs in a pause and a statement composed then ages from the resume
    /// a statement composed during a pause starts aging at the resume, and one composed before it keeps its age
    function test_compose_worksWhilePausedAndAgesFromTheResume() public {
        uint256 first = _composeOnce().sid;
        _age(first, 3 * H);
        _setPaused(true);

        uint256 supply = STATEMENTS.supply();
        uint256 second = _another();
        assertEq(second, supply + 1, "compose went through while paused");
        uint256 cost = _cost(second);
        vm.warp(block.timestamp + 5 days);
        assertEq(ctl.priceOf(second), _launch(cost, 0), "no age accrued in the pause");
        assertEq(ctl.priceOf(first), _launch(_cost(first), 3 * H), "the older statement keeps its age");

        _setPaused(false);
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

    // promise: SPEC 1 the eth bid runs in a pause
    /// the eth bid is unaffected: credits sell into it while paused
    function test_sellForEth_worksWhilePaused() public {
        _setPaused(true);
        uint256 size = core.pileSize();
        _fillEthPile(5);
        assertEq(core.pileSize(), size + 5, "the credits entered the pile");
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
            assertEq(ctl.priceOf(sids[j]), _launch(_cost(sids[j]), age), "the price is the curve at that age");
        }
    }

    // promise: SPEC 1 statementAge is wall time minus paused time
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_ageIsWallTimeMinusPausedTime(uint256 seed) public {
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
            } else if (op == 2 && ns < 3) {
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
