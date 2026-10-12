// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {Vm} from "forge-std/Vm.sol";
import {SaleBase} from "./Sale.t.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane} from "../src/interfaces/Interfaces.sol";
import {StatementInfoStub} from "./standins/StatementInfoStub.sol";

/// the owner pause of the sale controller on the live fork: `buy` refuses while paused, `priceOf` answers, the age a
/// statement's price falls with excludes every paused second, composing and the bid are unaffected
contract PauseTest is SaleBase {
    address internal buyer = address(0xB0B);

    function _setPaused(bool v) internal {
        vm.prank(owner);
        ctl.setPaused(v);
    }

    function test_launchValueIsUnpaused() public view {
        assertFalse(ctl.paused());
    }

    function test_setPaused_onlyTheLiveOwner() public {
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setPaused(false);
        assertFalse(ctl.paused());

        address heir = address(0x4E12);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setPaused(true);
        vm.prank(heir);
        ctl.setPaused(true);
        assertTrue(ctl.paused(), "the new owner pauses");
    }

    function test_setPaused_eventAndNoOpRepeats() public {
        vm.expectEmit(address(ctl));
        emit IControllerV1.PausedSet(true);
        _setPaused(true);
        assertTrue(ctl.paused());

        vm.recordLogs();
        _setPaused(true);
        assertEq(vm.getRecordedLogs().length, 0, "pausing a paused controller emits nothing");
        assertTrue(ctl.paused());

        vm.expectEmit(address(ctl));
        emit IControllerV1.PausedSet(false);
        _setPaused(false);
        assertFalse(ctl.paused());

        vm.recordLogs();
        _setPaused(false);
        assertEq(vm.getRecordedLogs().length, 0, "resuming a running controller emits nothing");
        assertFalse(ctl.paused());
    }

    function test_buy_revertsWhilePausedAndWorksAfterResume() public {
        uint256 sid = _composeOnce().sid;
        _setPaused(true);
        uint256 price = ctl.priceOf(sid);
        assertGt(price, 0, "priceOf answers while paused");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Paused.selector);
        ctl.buy{value: price}(sid);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Paused.selector);
        ctl.buy{value: 10 ether}(sid);
        assertTrue(_held(sid), "the statement is still held");
        assertEq(buyer.balance, 10 ether, "nothing was taken");

        _setPaused(false);
        _pay(buyer, sid, ctl.priceOf(sid));
        assertEq(STATEMENTS.ownerOf(sid), buyer, "sold after the resume");
    }

    /// the pause check comes first: a statement the core does not hold reverts `Paused`, not `NotForSale`
    function test_buy_pausedRefusesBeforeAnyOtherCheck() public {
        _setPaused(true);
        vm.expectRevert(IControllerV1.Paused.selector);
        ctl.buy(123_456_789);
        _setPaused(false);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.buy(123_456_789);
    }

    /// a statement 20 hours into its fall is at hour 20 of the fall after a pause of any length, and the fall goes on
    function testFuzz_priceIsFrozenAndResumesAtTheSameAge(uint32 length) public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 20 * H);
        uint256 before = ctl.priceOf(sid);
        assertEq(before, _launch(cost, 20 * H), "hour 20 of the launch curve");
        _setPaused(true);
        assertEq(ctl.priceOf(sid), before, "the price at the pause");
        vm.warp(block.timestamp + length);
        assertEq(ctl.priceOf(sid), before, "the price stays through the pause");
        _setPaused(false);
        assertEq(ctl.priceOf(sid), before, "the price at the resume");
        vm.warp(block.timestamp + 1 hours);
        assertEq(ctl.priceOf(sid), _launch(cost, 21 * H), "hour 21 an hour after the resume");
        assertLt(ctl.priceOf(sid), before);
    }

    function test_price_oneStatementAcrossTwoWindows() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 5 * H);
        _setPaused(true);
        vm.warp(block.timestamp + 2 days);
        _setPaused(false);
        vm.warp(block.timestamp + 5 * H);
        assertEq(ctl.priceOf(sid), _launch(cost, 10 * H), "5 hours, a 2 day pause, 5 hours");
        _setPaused(true);
        vm.warp(block.timestamp + 1 hours);
        _setPaused(false);
        vm.warp(block.timestamp + 10 * H);
        assertEq(ctl.priceOf(sid), _launch(cost, 20 * H), "and a second pause of 1 hour, 10 hours");
    }

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

    /// pausing a paused controller and resuming a running one open no window
    function test_noOpRepeatsOpenNoWindow() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 10 * H);
        _setPaused(false);
        _setPaused(true);
        vm.warp(block.timestamp + 1 days);
        _setPaused(true);
        vm.warp(block.timestamp + 1 days);
        _setPaused(false);
        _setPaused(false);
        assertEq(ctl.priceOf(sid), _launch(cost, 10 * H), "one window of 2 days, the age is 10 hours");
        vm.warp(block.timestamp + 1 hours);
        assertEq(ctl.priceOf(sid), _launch(cost, 11 * H));
    }

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
            _curve(cost, ctl.startBps(), 10_000, 100, 25, 7_500, frozenAge),
            "the start follows the anchor, the age is held"
        );
        _setPaused(false);
        assertEq(ctl.anchorBps(), 20_000);
    }

    /// with the anchor above 10_000 the price at the resume is at or below the price at the pause: the age is held, the
    /// start follows the decayed anchor
    function test_anchorAboveParDecaysAcrossAPause() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _anchor(30_000);
        _age(sid, 5 * H);
        uint256 atPause = ctl.priceOf(sid);
        uint256 anchorAtPause = ctl.anchorBps();
        assertGt(anchorAtPause, 10_000);
        _setPaused(true);
        vm.warp(block.timestamp + 2 * ctl.anchorHalfLife());
        _setPaused(false);
        assertLt(ctl.anchorBps(), anchorAtPause, "the anchor decayed in the pause");
        uint256 atResume = ctl.priceOf(sid);
        assertLe(atResume, atPause, "the price at the resume is at or below the price at the pause");
        assertEq(
            atResume,
            _curve(cost, ctl.startBps(), 10_000, 100, 25, 7_500, 5 * H),
            "the held age on the decayed anchor"
        );
    }

    /// `priceOf` against the real core with 1_000 closed windows, every account and slot cold, from the oldest statement
    function test_gas_priceOfWithManyWindowsOnTheRealCore() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256 n = 1_000;
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 100);
            _setPaused(true);
            vm.warp(block.timestamp + 100);
            _setPaused(false);
        }
        vm.cool(address(ctl));
        vm.cool(address(core));
        uint256 g = gasleft();
        uint256 price = ctl.priceOf(sid);
        uint256 used = g - gasleft();
        emit log_named_uint("priceOf gas, real core, 1000 closed windows, oldest statement, cold", used);
        assertEq(price, _launch(cost, n * 100), "the price is the curve at the age outside every window");
        assertLt(used, 200_000, "inside the 200_000 gas the lens gives a priceOf read");
    }

    /// the eth bid is unaffected: credits sell into it while paused
    function test_sellForEth_worksWhilePaused() public {
        _setPaused(true);
        uint256 size = core.pileSize(Lane.Eth);
        _fillEthPile(5);
        assertEq(core.pileSize(Lane.Eth), size + 5, "the credits entered the pile");
    }
}

/// the pause windows against an independent model, with a stand-in core that answers the three reads of the controller
contract PauseWindowsTest is SaleBase {
    uint256 internal constant COST = 1 ether;

    StatementInfoStub internal stub;
    IControllerV1 internal c;

    function setUp() public override {
        super.setUp();
        stub = new StatementInfoStub(owner);
        c = Prod.newController(address(stub), lc.sale);
    }

    function _toggle(bool v) internal {
        vm.prank(owner);
        c.setPaused(v);
    }

    /// the seconds of [from, to] inside the windows `ws[i]` to `we[i]` (`we[i]` zero: still open, counted to `to`)
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

    /// the price of every statement composed so far equals the launch curve at its age without the paused seconds
    function _checkAll(uint256[] memory comp, uint256 nc, uint256[] memory ws, uint256[] memory we, uint256 nw)
        internal
    {
        for (uint256 j; j < nc; ++j) {
            // forge-lint: disable-next-line(unsafe-typecast)
            stub.set(COST, uint64(comp[j]));
            uint256 age = block.timestamp - comp[j] - _overlap(ws, we, nw, comp[j], block.timestamp);
            assertEq(c.priceOf(0), _launch(COST, age), "the price is the curve at the age outside every window");
        }
    }

    /// pause windows of random length with statements composed before, during, between and after them, at the
    /// boundaries too (a step of 0 seconds is common). the model counts the overlap window by window
    function testFuzz_ageIsWallTimeMinusPausedTime(uint256 seed) public {
        uint256[] memory comp = new uint256[](24);
        uint256[] memory ws = new uint256[](24);
        uint256[] memory we = new uint256[](24);
        uint256 nc;
        uint256 nw;
        bool isPaused;
        comp[nc++] = block.timestamp - 10_000;
        comp[nc++] = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + ((h >> 64) % 4 == 0 ? 0 : h % 20_001));
            uint256 op = (h >> 32) % 4;
            if (op < 2) {
                isPaused = !isPaused;
                _toggle(isPaused);
                if (isPaused) {
                    ws[nw] = block.timestamp;
                    we[nw] = 0;
                    ++nw;
                } else {
                    we[nw - 1] = block.timestamp;
                }
            } else if (op == 2) {
                comp[nc++] = block.timestamp;
            } else {
                _toggle(isPaused);
            }
            assertEq(c.paused(), isPaused);
            _checkAll(comp, nc, ws, we, nw);
        }
    }

    /// the cost of a read with many windows: a binary search of one storage slot per halving, from the oldest statement
    function test_gas_readCostWithManyWindows() public {
        uint256 oldest = block.timestamp;
        uint256 n = 1_000;
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 100);
            _toggle(true);
            vm.warp(block.timestamp + 100);
            _toggle(false);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        stub.set(COST, uint64(oldest));
        vm.cool(address(c));
        uint256 g = gasleft();
        uint256 price = c.priceOf(0);
        uint256 used = g - gasleft();
        emit log_named_uint("priceOf gas, 1000 closed windows, oldest statement, cold", used);
        assertEq(price, _launch(COST, 1_000 * 100), "the price is the curve at the age outside every window");
        assertLt(used, 100_000, "well inside the 200_000 gas the lens gives a priceOf read");
    }

    /// a window opened and closed in one second removes no time and the later windows stay exact
    function test_zeroLengthWindowsRemoveNoTime() public {
        uint64 at = uint64(block.timestamp);
        stub.set(COST, at);
        _toggle(true);
        _toggle(false);
        _toggle(true);
        _toggle(false);
        vm.warp(block.timestamp + 3 hours);
        assertEq(c.priceOf(0), _launch(COST, 3 hours));
        _toggle(true);
        vm.warp(block.timestamp + 1 hours);
        _toggle(false);
        vm.warp(block.timestamp + 1 hours);
        assertEq(c.priceOf(0), _launch(COST, 4 hours));
    }
}
