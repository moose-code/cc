// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";

/// decision 89: chosen composition. a caller names 80 pile credits and a format, gated by `chosenComposeOn`, a least
/// coin balance `minCcToChoose`, and that every named credit is in the pile and past its window. `compose` shares the
/// internal path with the controller's default page. both produce the same statement record for the same 80 ids
contract ChosenComposeTest is Fixture {
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

    /// the 80 ids `src[0..79]` as a fixed array for `composeChosen`
    function _fixed(uint256[] memory src) internal pure returns (uint256[80] memory out) {
        for (uint256 i; i < PAGE; ++i) {
            out[i] = src[i];
        }
    }

    /// the first 80 of a pile page as a fixed array
    function _first80(uint256[] memory page) internal pure returns (uint256[80] memory out) {
        for (uint256 i; i < PAGE; ++i) {
            out[i] = page[i];
        }
    }

    function _on() internal {
        vm.prank(owner);
        core.setChosenComposeOn(true);
    }

    function _call(uint256[80] memory ids, uint8 format) internal {
        vm.fee(composeBasefee);
        vm.prank(chooser);
        core.composeChosen(ids, format);
    }

    // ------------------------------------------------------------------ gates

    function test_REVERT_toggleOff() public {
        uint256[] memory page = _pile(80);
        assertFalse(core.chosenComposeOn(), "off at launch");
        vm.expectRevert(ICore.ChosenComposeOff.selector);
        _call(_first80(page), 0);
    }

    function test_minCcToChoose_belowRevertsAtOrAbovePasses() public {
        uint256[] memory page = _pile(80);
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

    function test_format_eightRevertsZeroToSevenPass() public {
        uint256[] memory page = _pile(80);
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

    function test_REVERT_idNotInPile() public {
        uint256[] memory page = _pile(80);
        _on();
        uint256[80] memory ids = _first80(page);
        // a fresh credit the chooser owns but never sold into the pile
        uint256[] memory stray = _credits(chooser, 1);
        ids[40] = stray[0];
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, stray[0]));
        _call(ids, 0);
    }

    function test_REVERT_duplicateId() public {
        uint256[] memory page = _pile(80);
        _on();
        uint256[80] memory ids = _first80(page);
        // name the head twice, drop the tail: the second pull of the head reverts
        ids[79] = page[0];
        vm.expectRevert(abi.encodeWithSelector(ICore.NotInPile.selector, page[0]));
        _call(ids, 0);
    }

    // ------------------------------------------------------------------ window

    function test_window_saleOffComposesAtAnyAge() public {
        uint256[] memory page = _pile(80);
        _on();
        // the sale is off: a fresh pile composes at once
        uint256 supply = STATEMENTS.supply();
        vm.prank(owner);
        ctl.setCreditSaleOn(false);
        _call(_first80(page), 0);
        assertTrue(_isHeld(supply + 1), "composes while the sale is off regardless of age");
    }

    function test_window_insideRevertsWhileSaleOn() public {
        uint256[] memory page = _pile(80);
        _on();
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
        // every named credit was acquired now, inside its window: the gate reverts on the newest, the pile head here
        // since the whole page shares one acquisition time
        vm.expectRevert(abi.encodeWithSelector(ICore.InWindow.selector, page[0]));
        _call(_first80(page), 0);

        // past the window the same set composes
        _warp(ctl.creditWindow() + 1);
        uint256 supply = STATEMENTS.supply();
        _call(_first80(page), 0);
        assertTrue(_isHeld(supply + 1), "composes once every named credit is past its window");
    }

    /// a single credit inside its window blocks a set whose other 79 are past theirs
    function test_window_oneFreshCreditBlocksTheSet() public {
        _fillEthPile(79);
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
        _warp(ctl.creditWindow() + 1);
        // one fresh credit, still inside its window
        _fillEthPile(1);
        _on();
        uint256[] memory page = core.pilePage(0, 80);

        // the fresh credit is the newest and still inside its window, so the gate reverts naming it
        vm.expectRevert(abi.encodeWithSelector(ICore.InWindow.selector, page[PAGE - 1]));
        _call(_first80(page), 0);

        _warp(ctl.creditWindow() + 1);
        uint256 supply = STATEMENTS.supply();
        _call(_first80(page), 0);
        assertTrue(_isHeld(supply + 1), "composes once the fresh credit clears its window");
    }

    // ------------------------------------------------------------------ pile links

    /// chosen credits taken from the head, the middle and the tail leave the remaining credits in a valid list
    function test_pile_headMiddleTailLeaveValidLinks() public {
        uint256[] memory page = _pile(83);
        _on();
        // leave three interior credits in the pile, compose the other 80, which include the head and the tail
        uint256 leaveA = 1;
        uint256 leaveB = 42;
        uint256 leaveC = 81;
        uint256[80] memory ids;
        uint256 k;
        for (uint256 i; i < 83; ++i) {
            if (i == leaveA || i == leaveB || i == leaveC) continue;
            ids[k++] = page[i];
        }
        assertEq(k, PAGE, "exactly 80 chosen");

        _call(ids, 0);
        assertEq(core.pileSize(), 3, "three credits remain");
        uint256[] memory rest = core.pilePage(0, 3);
        assertEq(rest.length, 3, "the walk from the head returns the three remaining credits");
        assertEq(rest[0], page[leaveA], "oldest remaining");
        assertEq(rest[1], page[leaveB], "middle remaining");
        assertEq(rest[2], page[leaveC], "newest remaining");
    }

    // ------------------------------------------------------------------ record and event

    function test_record_costSumAndRatingRead() public {
        uint256[] memory page = _pile(80);
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

    function test_event_carriesCallerIdsFormatCost() public {
        uint256[] memory page = _pile(80);
        _on();
        uint256[80] memory ids = _first80(page);
        uint256 sum;
        for (uint256 i; i < PAGE; ++i) {
            (, uint256 c,) = core.creditInfo(page[i]);
            sum += c;
        }
        uint256 sid = STATEMENTS.supply() + 1;
        vm.fee(composeBasefee);
        vm.expectEmit(address(core));
        emit ICore.Composed(sid, ids, 3, sum, chooser);
        vm.prank(chooser);
        core.composeChosen(ids, 3);
    }

    // ------------------------------------------------------------------ parity with compose()

    /// the default page and a chosen call with the same 80 ids and format produce the same record
    function test_parity_composeEqualsComposeChosen() public {
        uint256[] memory page = _pile(80);
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

    function test_REVERT_retiredCoreBlocksIt() public {
        uint256[] memory page = _pile(80);
        uint256[80] memory ids = _first80(page);
        _on();
        // retire the core by migrating to a successor
        MigrationSink sink = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(sink));
        vm.prank(owner);
        core.migrate(1000);
        assertTrue(core.retired(), "the core is retired");

        vm.expectRevert(ICore.Retired.selector);
        vm.prank(chooser);
        core.composeChosen(ids, 0);
    }

    // ------------------------------------------------------------------ mixed credit sources

    /// credits bought through the eth bid and the balance token bid share one pile and compose through a chosen call
    function test_mix_ethBidAndBalanceTokenCredits() public {
        _enterPhase2();
        _fundPot(3 ether);
        xt.mint(address(core), 1e24);
        core.bookBalance();
        _setBalancePool();

        _fillEthPile(40);
        uint256[] memory xIds = _credits(seller, 40);
        vm.prank(seller);
        core.sellForBalance(xIds);
        assertEq(core.pileSize(), 80, "one pile holds both kinds");

        uint256[] memory page = core.pilePage(0, 80);
        uint256 sum;
        for (uint256 i; i < PAGE; ++i) {
            (, uint256 c,) = core.creditInfo(page[i]);
            sum += c;
        }
        _on();
        uint256 sid = STATEMENTS.supply() + 1;
        _call(_first80(page), 0);
        (bool held, uint256 cost,) = core.statementInfo(sid);
        assertTrue(held, "held");
        assertEq(cost, sum, "cost basis is the sum of the mixed credits' eth cost bases");
        assertEq(core.pileSize(), 0, "the pile is emptied");
    }

    // ------------------------------------------------------------------ gas

    function test_gas_composeChosen80() public {
        uint256[] memory page = _pile(80);
        _on();
        uint256[80] memory ids = _first80(page);
        vm.fee(composeBasefee);
        vm.prank(chooser);
        uint256 g = gasleft();
        core.composeChosen(ids, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("composeChosen 80 credits gas", used);
        assertLt(used, 16_777_216, "under the transaction gas cap");
    }
}
