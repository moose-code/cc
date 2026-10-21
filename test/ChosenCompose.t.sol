// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// decision 89: chosen composition. a caller names 80 pile credits and a format, gated by `chosenComposeOn`, a least
/// coin balance `minCcToChoose`, and that every named credit is in the pile and past its window. `compose` shares the
/// internal path with the controller's default page. both produce the same statement record for the same 80 ids
contract ChosenComposeTest is LiveFixture {
    uint256 internal constant PAGE = 80;
    address internal chooser;

    function setUp() public override {
        super.setUp();
        chooser = _user("chooser");
    }

    // ------------------------------------------------------------------ helpers

    /// fills the pile with `n` credits through the eth bid and returns the pile in order, oldest first
    function _pile(uint256 n) internal returns (uint256[] memory page) {
        _fillEthPile(n);
        page = core.pilePage(0, n);
    }

    /// the same, then past the credit window. the live credit sale is on, so composeChosen and compose take only
    /// credits past their window; the compose-mechanics tests name credits that are composable under the live sale,
    /// which the window test (its own subject) does not
    function _composablePile(uint256 n) internal returns (uint256[] memory page) {
        page = _pile(n);
        _warp(ctl.creditWindow() + 1);
    }

    /// the first 80 of a pile page as a fixed array
    function _first80(uint256[] memory page) internal pure returns (uint256[80] memory out) {
        for (uint256 i; i < PAGE; ++i) {
            out[i] = page[i];
        }
    }

    /// opens the door and sets the coin minimum to zero (the launch value is 1 coin, which the chooser does not hold)
    function _on() internal {
        vm.startPrank(owner);
        core.setChosenComposeOn(true);
        core.setMinCcToChoose(0);
        vm.stopPrank();
    }

    function _call(uint256[80] memory ids, uint8 format) internal {
        vm.fee(composeBasefee);
        vm.prank(chooser);
        core.composeChosen(ids, format);
    }

    // ------------------------------------------------------------------ gates

    // promise: INTEGRATION ChosenComposeOff
    function test_REVERT_toggleOff() public {
        uint256[] memory page = _pile(80);
        assertFalse(core.chosenComposeOn(), "off at launch");
        vm.expectRevert(ICore.ChosenComposeOff.selector);
        _call(_first80(page), 0);
    }

    // promise: INTEGRATION BelowMinCc
    function test_minCcToChoose_belowRevertsAtOrAbovePasses() public {
        uint256[] memory page = _composablePile(80);
        _on();
        // the chooser holds coin bought through the pool
        _buyCoin(chooser, 0.5 ether);
        uint256 bal = coin.balanceOf(chooser);
        assertGt(bal, 0, "the chooser holds coin");

        // a minimum above the balance refuses
        vm.prank(owner);
        core.setMinCcToChoose(uint96(bal + 1));
        vm.expectRevert(ICore.BelowMinCc.selector);
        _call(_first80(page), 0);

        // exactly the balance passes
        vm.prank(owner);
        core.setMinCcToChoose(uint96(bal));
        uint256 supply = STATEMENTS.supply();
        _call(_first80(page), 0);
        assertTrue(_isHeld(supply + 1), "the statement is held");
    }

    // promise: INTEGRATION BadFormat
    function test_format_eightRevertsZeroToSevenPass() public {
        uint256[] memory page = _composablePile(80);
        _on();
        uint256[80] memory ids = _first80(page);
        uint256 sid = STATEMENTS.supply() + 1;
        uint256 snap = vm.snapshotState();

        for (uint8 f; f <= 7; ++f) {
            _call(ids, f);
            assertTrue(_isHeld(sid), "a statement for each format 0..7");
            vm.revertToState(snap);
        }

        vm.expectRevert(ICore.BadFormat.selector);
        _call(ids, 8);
    }

    // promise: INTEGRATION NotInPile on composeChosen
    function test_REVERT_idNotInPile() public {
        uint256[] memory page = _composablePile(80);
        _on();
        uint256[80] memory ids = _first80(page);
        // a fresh credit the chooser owns but never sold into the pile
        uint256[] memory stray = _credits(chooser, 1);
        ids[40] = stray[0];
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, stray[0]));
        _call(ids, 0);
    }

    // ------------------------------------------------------------------ window

    // promise: INTEGRATION InWindow
    function test_window_insideRevertsWhileSaleOn() public {
        uint256[] memory page = _pile(80);
        _on();
        // the subject here is the window gate while the sale is on, so the sale is set on (its live value); the live
        // pile still holds credits inside their window, so the gate refuses the page. the specific credit it names is
        // live pile state, so the selector alone is asserted (not a pinned id)
        _setCreditSaleOn(true);
        vm.expectPartialRevert(ICore.InWindow.selector);
        _call(_first80(page), 0);

        // past the window the same set composes
        _warp(ctl.creditWindow() + 1);
        uint256 supply = STATEMENTS.supply();
        _call(_first80(page), 0);
        assertTrue(_isHeld(supply + 1), "composes once every named credit is past its window");
    }

    // ------------------------------------------------------------------ pile links

    // ------------------------------------------------------------------ record and event

    // promise: SPEC 1 chosen composition records the cost and rating of the 80 credits (decision 89)
    function test_record_costSumAndRatingRead() public {
        uint256[] memory page = _composablePile(80);
        _on();
        uint256 sum;
        for (uint256 i; i < PAGE; ++i) {
            (, uint256 c,) = core.creditInfo(page[i]);
            sum += c;
        }
        uint256 sid = STATEMENTS.supply() + 1;
        _call(_first80(page), 0);
        (bool held, uint256 cost,) = core.statementInfo(sid);
        assertTrue(held, "held");
        assertEq(cost, sum, "cost basis is the sum of the chosen credits' costs");
        assertEq(core.ratingOf(sid), STATEMENTS.creditScoreOf(sid), "rating is the read of the composed statement");
        assertGt(core.ratingOf(sid), 0, "rating is nonzero");
    }

    // promise: SPEC 1 the Core stores the composer of every statement (decision 111)
    /// the Core stores the composer of every statement, for `compose` and for `composeChosen`
    function test_record_composerIsTheCaller() public {
        uint256[] memory page = _composablePile(80);
        _on();
        uint256 sid = STATEMENTS.supply() + 1;
        _call(_first80(page), 0);
        assertEq(core.composerOf(sid), chooser, "composeChosen records its caller");
        _fillEthPile(80);
        uint256 sid2 = STATEMENTS.supply() + 1;
        vm.warp(block.timestamp + ctl.creditWindow() + 1);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        assertEq(core.composerOf(sid2), keeper, "compose records its caller");
        assertEq(core.composerOf(sid), chooser, "and leaves the earlier one");
        // a sold statement keeps its composer
        _buy(chooser, sid);
        assertEq(core.composerOf(sid), chooser, "the composer stays after the sale");
        assertEq(core.composerOf(sid2 + 100), address(0), "a statement that was never composed has none");
    }

    // ------------------------------------------------------------------ parity with compose()

    // promise: SPEC 1 compose and composeChosen run the same internal path (decision 113)
    /// the default page and a chosen call with the same 80 ids and format produce the same record
    function test_parity_composeEqualsComposeChosen() public {
        uint256[] memory page = _composablePile(80);
        uint256[80] memory ids = _first80(page);
        uint256 sid = STATEMENTS.supply() + 1;

        uint256 snap = vm.snapshotState();

        // the default path
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        (bool heldA, uint256 costA,) = core.statementInfo(sid);
        uint256 ratingA = core.ratingOf(sid);

        vm.revertToState(snap);

        // the chosen path, same ids, same format
        _on();
        _call(ids, 0);
        (bool heldB, uint256 costB,) = core.statementInfo(sid);
        uint256 ratingB = core.ratingOf(sid);

        assertEq(heldA, heldB, "both hold the statement");
        assertEq(costA, costB, "same cost basis");
        assertEq(ratingA, ratingB, "same rating");
        assertEq(sid, STATEMENTS.supply(), "same statement id");
    }

    // ------------------------------------------------------------------ retired core

    // ------------------------------------------------------------------ mixed credit sources

    // ------------------------------------------------------------------ gas
}
