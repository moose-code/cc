// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Lane, Settings, IStatements} from "../src/interfaces/Interfaces.sol";
import {IAuctionHouse} from "../src/interfaces/AuctionHouse.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {Vm} from "forge-std/Vm.sol";

/// `setSuccessor`, `lockSuccessor` and `migrate` of the Core on the fork: the real Core, Credits, Statements, house and
/// pool, the stand in exit module and token, and `MigrationSink` as the successor. the first `migrate` retires the Core:
/// six doors refuse with `Retired`, and settling, exits, sales of statements, both buybacks and the owner functions work
contract MigrateTest is Fixture {
    MigrationSink internal sink;
    address internal stranger = address(0x5757);

    /// the statements of `_world`: listed without a bid, listed with a live bid, sold with the record not settled, and
    /// held by the core on the exit lane
    struct World {
        uint256 listed;
        uint256 bidOn;
        uint256 sold;
        uint256 exitLane;
    }

    function setUp() public override {
        super.setUp();
        sink = new MigrationSink();
    }

    function _setSuccessor() internal {
        vm.prank(owner);
        core.setSuccessor(address(sink));
    }

    function _migrate(uint256 maxCredits) internal {
        vm.prank(owner);
        core.migrate(maxCredits);
    }

    function _listedStatement() internal returns (uint256 sid) {
        _fillEthPile(80);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    function _exitLaneStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        uint256 supply = STATEMENTS.supply();
        core.composeExit();
        sid = supply + 1;
    }

    /// pots in both currencies, piles in both lanes, and one statement of each kind
    function _world() internal returns (World memory w) {
        _enterPhase2();
        _fundPot(3 ether);
        // the first eth lane statement exits, which fills the exit pots
        _fillExitBuyback();
        w.listed = _listedStatement();
        w.bidOn = _listedStatement();
        _bid(address(0xB1D), w.bidOn, _live(w.bidOn).reserve);
        w.sold = _listedStatement();
        _bid(address(0xB2D), w.sold, _live(w.sold).reserve);
        _endAuction(w.sold);
        // the proceeds of the sale are booked: half to the pot, half to the coin buyback pot
        _collectSales();
        w.exitLane = _exitLaneStatement();
        // credits left in both piles
        _fillEthPile(7);
        uint256[] memory ids = _credits(seller, 5);
        vm.prank(seller);
        core.sellForExitToken(ids);
    }

    function _heldCount() internal view returns (uint256) {
        return core.heldStatements().length;
    }

    // ------------------------------------------------------------------ the owner doors

    function test_OK_setSuccessorTakesACodeAddressOrZero() public {
        assertEq(core.successor(), address(0), "no successor at launch");
        assertFalse(core.successorLocked(), "unlocked at launch");
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.SuccessorSet(address(sink));
        _setSuccessor();
        assertEq(core.successor(), address(sink));
        vm.prank(owner);
        core.setSuccessor(address(0));
        assertEq(core.successor(), address(0));
        vm.expectRevert(abi.encodeWithSelector(ICore.NoCode.selector, address(0xE0A)));
        vm.prank(owner);
        core.setSuccessor(address(0xE0A));
    }

    function test_REVERT_migrateNeedsASuccessor() public {
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
        assertFalse(core.retired(), "a refused migrate retired the core");
    }

    function test_OK_theLockClosesSetSuccessorAndKeepsMigrate() public {
        _setSuccessor();
        vm.expectEmit(false, false, false, true, address(core));
        emit ICore.SuccessorLocked();
        vm.prank(owner);
        core.lockSuccessor();
        assertTrue(core.successorLocked());
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(0));
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(sink));
        assertEq(core.successor(), address(sink), "the locked successor changed");
        _fundPot(1 ether);
        uint256 total = core.ethPot();
        _migrate(10);
        assertEq(sink.ethReceived(), total, "migrate stopped working after the lock");
    }

    function test_OK_aLockWithAZeroSuccessorDisablesMigrateForGood() public {
        vm.prank(owner);
        core.lockSuccessor();
        assertTrue(core.successorLocked());
        assertEq(core.successor(), address(0));
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
        vm.expectRevert(abi.encodeWithSelector(ICore.Locked.selector, bytes32("successor")));
        vm.prank(owner);
        core.setSuccessor(address(sink));
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
    }

    function test_REVERT_onlyTheOwner() public {
        _setSuccessor();
        vm.startPrank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setSuccessor(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.lockSuccessor();
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10);
        vm.stopPrank();
        // the keeper and the creator have no power either
        vm.prank(keeper);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10);
        assertFalse(core.successorLocked());
        assertEq(core.successor(), address(sink));
    }

    // ------------------------------------------------------------------ a full migration

    /// the record, house state and holder of a statement, as one hash
    function _fingerprint(uint256 sid) internal view returns (bytes32) {
        (bool held, Lane lane, uint256 cost, uint64 clockStart) = core.statementInfo(sid);
        return keccak256(abi.encode(held, lane, cost, clockStart, _live(sid), STATEMENTS.ownerOf(sid)));
    }

    function test_OK_potsAndCreditsMove() public {
        _world();
        _setSuccessor();

        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 xPot = core.xPot();
        uint256 xBuyback = core.xToBuyback();
        assertTrue(pot > 0 && buyback > 0 && xPot > 0 && xBuyback > 0, "setup: every pot holds something");
        uint256[] memory ethIds = core.pilePage(Lane.Eth, 0, 100);
        uint256[] memory exitIds = core.pilePage(Lane.Exit, 0, 100);
        assertEq(ethIds.length, 7, "setup: eth pile");
        assertEq(exitIds.length, 5, "setup: exit pile");
        uint256 balance = address(core).balance;
        uint256 xBalance = xt.balanceOf(address(core));
        uint256 coinBalance = coin.balanceOf(address(core));

        assertFalse(core.retired(), "setup: not retired");
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.EngineRetired(address(sink));
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), pot, xPot, 12);
        _migrate(1000);

        assertTrue(core.retired(), "the first migrate did not retire the core");
        // eth: the sink got the pot, the buyback pot stays, the rest of the balance stays
        assertEq(sink.ethReceived(), pot, "the sink did not get the eth pot");
        assertEq(sink.sends(), 1, "one plain call");
        assertEq(core.ethPot(), 0, "ethPot");
        assertEq(core.ethToBuyback(), buyback, "ethToBuyback stays");
        assertEq(address(core).balance, balance - pot, "the core balance");
        // exit token
        assertEq(xt.balanceOf(address(sink)), xPot, "the sink did not get xPot");
        assertEq(core.xPot(), 0, "xPot");
        assertEq(core.xToBuyback(), xBuyback, "xToBuyback stays");
        assertEq(xt.balanceOf(address(core)), xBalance - xPot, "the core exit token balance");
        // the coin stays
        assertEq(coin.balanceOf(address(core)), coinBalance, "the coin moved");
        // credits
        for (uint256 i; i < ethIds.length; ++i) {
            assertEq(CREDITS.ownerOf(ethIds[i]), address(sink), "an eth lane credit did not move");
            (bool inPile,,,) = core.creditInfo(ethIds[i]);
            assertFalse(inPile, "a moved credit is still in the pile");
        }
        for (uint256 i; i < exitIds.length; ++i) {
            assertEq(CREDITS.ownerOf(exitIds[i]), address(sink), "an exit lane credit did not move");
            (bool inPile,,,) = core.creditInfo(exitIds[i]);
            assertFalse(inPile, "a moved credit is still in the pile");
        }
        assertEq(core.pileSize(Lane.Eth), 0, "eth pile size");
        assertEq(core.pileSize(Lane.Exit), 0, "exit pile size");
        assertEq(core.pilePage(Lane.Eth, 0, 1).length, 0, "eth pile head");
        assertEq(core.pilePage(Lane.Exit, 0, 1).length, 0, "exit pile head");
        _solvent();
    }

    function test_OK_everyHeldStatementStaysAsItWas() public {
        World memory w = _world();
        _setSuccessor();
        uint256[4] memory sids = [w.listed, w.bidOn, w.sold, w.exitLane];
        bytes32[4] memory before;
        for (uint256 i; i < 4; ++i) {
            before[i] = _fingerprint(sids[i]);
        }
        uint256[] memory heldBefore = core.heldStatements();
        assertEq(heldBefore.length, 4, "setup: four statements on the books");
        _migrate(1000);
        for (uint256 i; i < 4; ++i) {
            assertEq(_fingerprint(sids[i]), before[i], "a statement changed");
        }
        uint256[] memory heldAfter = core.heldStatements();
        assertEq(heldAfter.length, heldBefore.length, "the held list changed");
        for (uint256 i; i < heldAfter.length; ++i) {
            assertEq(heldAfter[i], heldBefore[i], "the held order changed");
        }
        assertEq(STATEMENTS.ownerOf(w.listed), address(house), "the listing left the house");
        assertEq(STATEMENTS.ownerOf(w.exitLane), address(core), "the exit lane statement left the core");
        assertEq(STATEMENTS.ownerOf(w.sold), address(0xB2D), "the winner lost the statement");
        assertEq(STATEMENTS.balanceOf(address(sink)), 0, "a statement reached the successor");
    }

    function test_OK_theOldEngineSellsOutItsStatementsAndASecondMigrateMovesTheProceeds() public {
        World memory w = _world();
        _setSuccessor();
        _migrate(1000);
        uint256 ethBefore = sink.ethReceived();
        uint256 xBefore = xt.balanceOf(address(sink));
        // the auction with a bid ends and the sale settles
        _endAuction(w.bidOn);
        core.syncStatement(w.bidOn);
        core.syncStatement(w.sold);
        assertEq(_heldCount(), 2, "two statements left on the books");
        // a listing without a bid exits to the exit token
        vm.warp(block.timestamp + core.settings().exitAfter);
        // the pots are empty after the migration: the exit reimbursement of the caller clamps at the pot
        assertEq(core.ethPot(), 0, "setup: the eth pot is empty");
        vm.fee(composeBasefee);
        vm.txGasPrice(composeBasefee);
        uint256 callerBalance = address(this).balance;
        core.exitStatement(w.listed);
        core.exitStatement(w.exitLane);
        assertEq(core.ethPot(), 0, "the exit took eth from an empty pot");
        assertEq(address(this).balance, callerBalance, "the caller was repaid from an empty pot");
        assertEq(_heldCount(), 0, "the exits left nothing on the books");
        assertGt(core.xPot() + core.xToBuyback(), 0, "the exit did not fill the exit pots");
        // the proceeds of the sales are booked by collectSales. the pot share moves in the next call, the buyback
        // share stays
        uint256 buybackBefore = core.ethToBuyback();
        _collectSales();
        uint256 booked = core.ethPot();
        uint256 xBooked = core.xPot();
        assertGt(booked, 0, "the proceeds were booked");
        assertGt(core.ethToBuyback(), buybackBefore, "the buyback share was booked");
        uint256 buybackStays = core.ethToBuyback();
        uint256 xBuybackStays = core.xToBuyback();
        _migrate(1000);
        assertEq(sink.ethReceived(), ethBefore + booked, "the second call did not move the new eth");
        assertEq(xt.balanceOf(address(sink)), xBefore + xBooked, "the second call did not move the new exit token");
        assertEq(core.ethPot(), 0, "the pot is zero again");
        assertEq(core.ethToBuyback(), buybackStays, "the buyback pot stays");
        assertEq(core.xPot(), 0, "xPot is zero again");
        assertEq(core.xToBuyback(), xBuybackStays, "the exit buyback pot stays");
        assertEq(STATEMENTS.balanceOf(address(sink)), 0, "a statement reached the successor");
        // a call with nothing left to move does nothing
        uint256 sends = sink.sends();
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), 0, 0, 0);
        _migrate(1000);
        assertEq(sink.sends(), sends, "an empty call sent eth");
        _solvent();
    }

    function test_OK_sellToAfterAMigrationBooksTheProceeds() public {
        uint256 sid = _listedStatement();
        _setSuccessor();
        _migrate(1000);
        assertEq(core.ethPot(), 0, "setup: the pot is empty");
        uint256 buybackBefore = core.ethToBuyback();
        vm.prank(owner);
        ctl.setBuyOnly(true);
        uint256 price = ctl.priceOf(sid);
        vm.deal(address(0xB1D), price);
        vm.prank(address(0xB1D));
        ctl.buy{value: price}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D), "the buyer does not hold the statement");
        assertGt(core.ethPot(), 0, "the proceeds were not booked to the pot");
        assertGt(core.ethToBuyback(), buybackBefore, "the proceeds were not booked to the buyback pot");
        _solvent();
    }

    function test_OK_buybackAfterAMigrationBurnsTheRetainedBuybackPotAndCollectsWaitingSalesFirst() public {
        // one sale is collected: its buyback share is booked and stays after the migrate
        uint256 first = _listedStatement();
        _bid(address(0xB1D), first, _live(first).reserve);
        _endAuction(first);
        _collectSales();
        // a second sale ends and its proceeds wait in the house
        uint256 sid = _listedStatement();
        _bid(address(0xB2D), sid, _live(sid).reserve);
        _endAuction(sid);
        assertGt(_owedByHouse(), 0, "setup: the sale proceeds are uncollected");
        _setSuccessor();
        _migrate(1000);
        uint256 retained = core.ethToBuyback();
        assertGt(retained, 0, "setup: the buyback pot stays after the migrate");
        assertEq(core.ethPot(), 0, "setup: the pot moved");
        uint256 supply = coin.totalSupply();
        vm.roll(block.number + 200);
        core.buyback();
        assertLt(coin.totalSupply(), supply, "the buyback did not burn coin");
        assertEq(_owedByHouse(), 0, "the buyback left the proceeds in the house");
        assertGt(core.ethPot(), 0, "the pot share of the sale was not booked");
        _solvent();
    }

    function test_OK_aListingWithoutABidStaysListedAndSells() public {
        uint256 sid = _listedStatement();
        bytes32 before = _fingerprint(sid);
        _setSuccessor();
        _migrate(10);
        assertEq(_fingerprint(sid), before, "the listing changed");
        assertEq(STATEMENTS.ownerOf(sid), address(house), "the statement left the house");
        _bid(address(0xB1D), sid, _live(sid).reserve);
        _endAuction(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(0xB1D), "the bidder did not win");
        _collectSales();
        assertGt(core.ethPot() + core.ethToBuyback(), 0, "the sale was not booked");
    }

    function test_OK_batchesOfOneMoveOneCreditPerPileAtATime() public {
        _world();
        _setSuccessor();
        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 xBuyback = core.xToBuyback();
        uint256 eth0 = core.pileSize(Lane.Eth);
        uint256 exit0 = core.pileSize(Lane.Exit);
        uint256 held = _heldCount();
        _migrate(1);
        // eth and exit token are not batched: one call moves all of them
        assertEq(sink.ethReceived(), pot, "the first call moves all of the pot");
        assertEq(core.ethToBuyback(), buyback, "the first call leaves the buyback pot");
        assertEq(core.xPot(), 0, "the first call moves all of xPot");
        assertEq(core.xToBuyback(), xBuyback, "the first call leaves the exit buyback pot");
        assertEq(core.pileSize(Lane.Eth), eth0 - 1, "one eth credit per call");
        assertEq(core.pileSize(Lane.Exit), exit0 - 1, "one exit credit per call");
        assertEq(CREDITS.balanceOf(address(sink)), 2, "one credit per pile reached the successor");
        // a call drains the rest of the piles one by one
        uint256 calls = 1;
        while (core.pileSize(Lane.Eth) != 0 || core.pileSize(Lane.Exit) != 0) {
            _migrate(1);
            ++calls;
            assertLe(calls, eth0, "too many calls");
        }
        assertEq(calls, eth0, "the larger pile sets the number of calls");
        assertEq(CREDITS.balanceOf(address(core)), 0, "credits left in the core");
        assertEq(CREDITS.balanceOf(address(sink)), eth0 + exit0, "the successor holds every credit");
        assertEq(_heldCount(), held, "the statements changed");
    }

    function test_OK_aZeroBatchMovesOnlyThePots() public {
        _world();
        _setSuccessor();
        uint256 eth = core.ethPot();
        uint256 x = core.xPot();
        uint256 held = _heldCount();
        uint256 ethPile = core.pileSize(Lane.Eth);
        uint256 exitPile = core.pileSize(Lane.Exit);
        _migrate(0);
        assertEq(sink.ethReceived(), eth);
        assertEq(xt.balanceOf(address(sink)), x);
        assertEq(core.pileSize(Lane.Eth), ethPile, "credits moved with a zero batch");
        assertEq(core.pileSize(Lane.Exit), exitPile, "credits moved with a zero batch");
        assertEq(_heldCount(), held, "statements changed with a zero batch");
    }

    function test_OK_forcedEthAboveTheTrackersStays() public {
        _fundPot(1 ether);
        _setSuccessor();
        uint256 tracked = core.ethPot();
        vm.deal(address(core), address(core).balance + 1 ether);
        uint256 balance = address(core).balance;
        _migrate(10);
        assertEq(sink.ethReceived(), tracked);
        assertEq(address(core).balance, balance - tracked, "the forced eth moved");
        // skim books it, and the next call moves it
        core.skim();
        assertGe(core.ethPot(), 1 ether - 1, "skim did not book the forced eth");
        _migrate(10);
        assertGe(sink.ethReceived(), tracked + 1 ether - 1, "the booked eth did not move");
    }

    // ------------------------------------------------------------------ a successor that misbehaves

    function test_REVERT_aSuccessorThatRefusesEthLeavesEverythingInPlace() public {
        _world();
        _setSuccessor();
        sink.setRefuse(true);
        uint256 pot = core.ethPot();
        uint256 held = _heldCount();
        uint256 ethPile = core.pileSize(Lane.Eth);
        uint256 x = core.xPot();
        vm.expectRevert(ICore.CallFailed.selector);
        _migrate(100);
        assertFalse(core.retired(), "a failed migrate retired the core");
        assertEq(core.ethPot(), pot, "pot changed");
        assertEq(core.xPot(), x, "exit pot changed");
        assertEq(core.pileSize(Lane.Eth), ethPile, "pile changed");
        assertEq(_heldCount(), held, "statements changed");
        // the owner points at another successor
        MigrationSink other = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(other));
        _migrate(100);
        assertGt(other.ethReceived(), 0);
    }

    function test_OK_aSuccessorThatCallsBackIsRefused() public {
        _fundPot(1 ether);
        // the successor is the owner and tries to run `migrate` again from its `receive`
        vm.prank(owner);
        core.transferOwnership(address(sink));
        sink.exec(address(core), abi.encodeCall(ICore.acceptOwnership, ()));
        sink.exec(address(core), abi.encodeCall(ICore.setSuccessor, (address(sink))));
        sink.setCall(address(core), abi.encodeCall(ICore.migrate, (10)));
        uint256 total = core.ethPot();
        (bool ok,) = sink.exec(address(core), abi.encodeCall(ICore.migrate, (10)));
        assertTrue(ok, "the outer migrate failed");
        assertTrue(sink.called(), "the sink did not call back");
        assertFalse(sink.calledOk(), "the nested migrate went through");
        assertEq(bytes4(sink.calledOut()), bytes4(0xab143c06), "not the reentrancy error");
        assertEq(sink.ethReceived(), total);
    }

    // ------------------------------------------------------------------ the engine afterwards

    function _engineRetiredLogs() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ICore.EngineRetired.selector) ++n;
        }
    }

    function test_OK_retiredIsOneWayAndLogsOnce() public {
        _fundPot(1 ether);
        _setSuccessor();
        assertFalse(core.retired(), "retired before a migrate");
        vm.recordLogs();
        _migrate(0);
        assertEq(_engineRetiredLogs(), 1, "the first migrate logs EngineRetired once");
        assertTrue(core.retired());
        vm.recordLogs();
        _migrate(0);
        _migrate(10);
        assertEq(_engineRetiredLogs(), 0, "a later migrate logged EngineRetired");
        assertTrue(core.retired(), "a later migrate cleared the flag");
        // changing the successor does not reopen the doors
        vm.prank(owner);
        core.setSuccessor(address(0));
        assertTrue(core.retired(), "clearing the successor cleared the flag");
    }

    function test_OK_aMigrateThatMovesNothingRetires() public {
        _setSuccessor();
        assertEq(core.ethPot(), 0, "setup: empty pot");
        _migrate(0);
        assertTrue(core.retired());
    }

    /// a retired core holding a credit that is outside the piles (for `adopt`), a seller credit, and a funded pot
    function _retiredWithCredits() internal returns (uint256[] memory ids) {
        _enterPhase2();
        _fundPot(3 ether);
        ids = _credits(seller, 2);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[1]);
        _setSuccessor();
        _migrate(1000);
    }

    /// the refused door left the credits, the pots and the piles as they were
    function _assertRefusedDoorChangedNothing(uint256[] memory ids, uint256 pot, uint256 xPot) internal view {
        assertEq(CREDITS.ownerOf(ids[0]), seller, "a refused call moved the credit");
        (bool inPile,,,) = core.creditInfo(ids[1]);
        assertFalse(inPile, "a refused call booked the credit");
        assertEq(core.ethPot(), pot, "ethPot");
        assertEq(core.xPot(), xPot, "xPot");
        assertEq(core.pileSize(Lane.Eth), 0, "eth pile");
        assertEq(core.pileSize(Lane.Exit), 0, "exit pile");
    }

    function test_REVERT_aRetiredCoreRefusesSellForEth() public {
        uint256[] memory ids = _retiredWithCredits();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        vm.startPrank(seller);
        vm.expectRevert(ICore.Retired.selector);
        core.sellForEth(_one(ids[0]));
        vm.expectRevert(ICore.Retired.selector);
        core.sellForEth(_one(ids[0]), 0);
        vm.stopPrank();
        _assertRefusedDoorChangedNothing(ids, pot, xPot);
    }

    function test_REVERT_aRetiredCoreRefusesSellForExitToken() public {
        uint256[] memory ids = _retiredWithCredits();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        vm.startPrank(seller);
        vm.expectRevert(ICore.Retired.selector);
        core.sellForExitToken(_one(ids[0]));
        vm.expectRevert(ICore.Retired.selector);
        core.sellForExitToken(_one(ids[0]), 0);
        vm.stopPrank();
        _assertRefusedDoorChangedNothing(ids, pot, xPot);
    }

    function test_REVERT_aRetiredCoreRefusesBuyListing() public {
        uint256[] memory ids = _retiredWithCredits();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        vm.expectRevert(ICore.Retired.selector);
        core.buyListing(0, "", ids[0], address(0xA110C));
        _assertRefusedDoorChangedNothing(ids, pot, xPot);
    }

    function test_REVERT_aRetiredCoreRefusesAdopt() public {
        uint256[] memory ids = _retiredWithCredits();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        vm.expectRevert(ICore.Retired.selector);
        core.adopt(_one(ids[1]));
        _assertRefusedDoorChangedNothing(ids, pot, xPot);
    }

    function test_REVERT_aRetiredCoreRefusesCompose() public {
        uint256[] memory ids = _retiredWithCredits();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        vm.fee(composeBasefee);
        vm.expectRevert(ICore.Retired.selector);
        vm.prank(keeper);
        core.compose();
        _assertRefusedDoorChangedNothing(ids, pot, xPot);
    }

    function test_REVERT_aRetiredCoreRefusesComposeExit() public {
        uint256[] memory ids = _retiredWithCredits();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        vm.expectRevert(ICore.Retired.selector);
        vm.prank(keeper);
        core.composeExit();
        _assertRefusedDoorChangedNothing(ids, pot, xPot);
    }

    /// a sale whose delivery to the winner fails on the house is unwound after 30 days and returns the statement to the
    /// core. the retired core relists it through `syncStatement`
    function test_OK_aRetiredCoreRelistsAnUnwoundSale() public {
        uint256 sid = _listedStatement();
        _setSuccessor();
        _migrate(1000);
        assertTrue(core.retired());

        Live memory l = _live(sid);
        address winner = address(0xA11CE);
        _bid(winner, sid, l.reserve);
        vm.mockCallRevert(
            address(STATEMENTS),
            abi.encodeWithSelector(IStatements.transferFrom.selector, address(house), winner, sid),
            "cannot receive"
        );
        _endAuction(sid);
        _warp(30 days + 1);
        house.unwindStuckLot{gas: END_GAS}(l.auctionId);
        vm.clearMockedCalls();
        assertEq(STATEMENTS.ownerOf(sid), address(core), "the unwind did not return the statement");
        assertEq(uint256(_live(sid).status), uint256(ICore.StatementStatus.Returned));

        core.syncStatement(sid);
        Live memory relisted = _live(sid);
        assertEq(uint256(relisted.status), uint256(ICore.StatementStatus.Listed), "not relisted");
        assertEq(relisted.auctionId, l.auctionId + 1, "not a new auction");
        assertEq(STATEMENTS.ownerOf(sid), address(house), "the statement is not on the house");
        assertTrue(core.retired(), "the relist cleared the flag");
        _solvent();
    }

    /// an exit token whose transfer reverts (mode 1) or returns false (mode 2): the eth leg, the credit leg and the
    /// retired flag go through, `xPot`, `xToBuyback` and the rate state stay, and a later migrate with a working token
    /// moves them
    function _exitTokenLegSkips(uint8 mode) internal {
        _world();
        _setSuccessor();
        uint256 pot = core.ethPot();
        uint256 xPot = core.xPot();
        uint256 xBuyback = core.xToBuyback();
        assertTrue(xPot > 0 && xBuyback > 0, "setup: the exit token pots hold something");
        uint256 credits = core.pileSize(Lane.Eth) + core.pileSize(Lane.Exit);
        uint256 xBalance = xt.balanceOf(address(core));
        xt.setTransferMode(mode);

        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.ExitTokenMigrationSkipped(address(sink), xPot);
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), pot, 0, credits);
        _migrate(1000);

        assertTrue(core.retired(), "the skipped leg blocked the retirement");
        assertEq(sink.ethReceived(), pot, "the eth leg did not go through");
        assertEq(core.ethPot(), 0, "ethPot");
        assertEq(CREDITS.balanceOf(address(sink)), credits, "the credit leg did not go through");
        assertEq(core.xPot(), xPot, "xPot changed");
        assertEq(core.xToBuyback(), xBuyback, "xToBuyback changed");
        assertEq(xt.balanceOf(address(core)), xBalance, "the exit token moved");
        assertEq(xt.balanceOf(address(sink)), 0, "the successor got exit token");
        _solvent();

        xt.setTransferMode(0);
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), 0, xPot, 0);
        _migrate(1000);
        assertEq(core.xPot(), 0, "xPot after the working token");
        assertEq(core.xToBuyback(), xBuyback, "xToBuyback after the working token");
        assertEq(xt.balanceOf(address(sink)), xPot, "the later migrate did not move xPot");
        _solvent();
    }

    function test_OK_aRevertingExitTokenSkipsItsLegAndTheEngineRetires() public {
        _exitTokenLegSkips(1);
    }

    function test_OK_anExitTokenReturningFalseSkipsItsLegAndTheEngineRetires() public {
        _exitTokenLegSkips(2);
    }

    function test_REVERT_aNonOwnerMigrateLeavesTheCoreActive() public {
        _fundPot(1 ether);
        _setSuccessor();
        uint256 pot = core.ethPot();
        vm.prank(stranger);
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.migrate(10);
        assertFalse(core.retired(), "a refused migrate retired the core");
        assertEq(core.ethPot(), pot, "a refused migrate moved the pot");
        assertEq(sink.ethReceived(), 0, "the successor received eth");
    }

    /// a pile that a partial batch leaves behind can be migrated by later calls, and cannot be composed
    function test_OK_aPartialBatchLeavesThePileMigratableAndComposeIsRefused() public {
        _fillEthPile(80);
        assertEq(core.pileSize(Lane.Eth), 80, "setup: a full page");
        _setSuccessor();
        _migrate(1);
        assertEq(core.pileSize(Lane.Eth), 79, "one credit moved");
        vm.fee(composeBasefee);
        vm.expectRevert(ICore.Retired.selector);
        vm.prank(keeper);
        core.compose();
        assertEq(core.pileSize(Lane.Eth), 79, "a refused compose took credits");
        _migrate(40);
        assertEq(core.pileSize(Lane.Eth), 39);
        _migrate(1000);
        assertEq(core.pileSize(Lane.Eth), 0);
        assertEq(CREDITS.balanceOf(address(core)), 0, "credits left in the core");
        assertEq(CREDITS.balanceOf(address(sink)), 80, "the successor holds every credit");
    }

    function test_OK_aRetiredCoreStillBooksFeesAndSkims() public {
        Settings memory st = core.settings();
        st.feeToBuybackBps = 1000;
        _setSettings(st);
        _fundPot(1 ether);
        _setSuccessor();
        _migrate(1000);
        uint256 retained = core.ethToBuyback();
        assertEq(core.ethPot(), 0, "setup: the pot moved");
        _buyCoin(funder, 3 ether);
        assertGt(core.ethPot(), 0, "fees were not booked to the pot");
        assertGt(core.ethToBuyback(), retained, "fees were not booked to the buyback pot");
        uint256 pot = core.ethPot();
        vm.deal(address(core), address(core).balance + 1 ether);
        core.skim();
        assertGe(core.ethPot(), pot + 1 ether, "skim did not book the forced eth");
        _solvent();
    }

    function test_OK_aRetiredCoreStillRepricesSyncsCollectsAndExits() public {
        World memory w = _world();
        _setSuccessor();
        _migrate(1000);
        // reprice a listing without a bid
        uint256 reserve = _live(w.listed).reserve;
        Settings memory st = core.settings();
        st.saleFloorBps = 12_000;
        _setSettings(st);
        core.repriceStatement(w.listed);
        assertGt(_live(w.listed).reserve, reserve, "the listing was not repriced");
        // two sales settle and their proceeds are collected
        _endAuction(w.bidOn);
        core.syncStatement(w.bidOn);
        core.syncStatement(w.sold);
        uint256 pot = core.ethPot();
        _collectSales();
        assertGt(core.ethPot(), pot, "the proceeds were not booked");
        // the two statements left on the books exit
        vm.warp(block.timestamp + core.settings().exitAfter);
        uint256 x = core.xPot() + core.xToBuyback();
        core.exitStatement(w.listed);
        core.exitStatement(w.exitLane);
        assertEq(_heldCount(), 0, "the exits left statements on the books");
        assertGt(core.xPot() + core.xToBuyback(), x, "the exit did not fill the exit pots");
        // the next migrate moves the new eth pot and the new xPot
        uint256 ethBefore = sink.ethReceived();
        uint256 xBefore = xt.balanceOf(address(sink));
        uint256 booked = core.ethPot();
        uint256 xBooked = core.xPot();
        _migrate(0);
        assertEq(sink.ethReceived(), ethBefore + booked, "the new pot did not move");
        assertEq(xt.balanceOf(address(sink)), xBefore + xBooked, "the new xPot did not move");
        _solvent();
    }

    /// the exit buyback pot that existed at the migration stays in the retired engine and `buybackExit` sells it
    function test_OK_xToBuybackStaysAndBuybackExitSellsItAfterMigrate() public {
        _world();
        uint256 xBuyback = core.xToBuyback();
        assertGt(xBuyback, 0, "setup: the exit buyback pot holds exit token");
        _setSuccessor();
        _migrate(1000);
        assertEq(core.xToBuyback(), xBuyback, "migrate moved xToBuyback");
        assertEq(xt.balanceOf(address(core)), xBuyback, "the retired engine holds exactly the exit buyback pot");
        address taker = _user("taker");
        _buyCoin(taker, 20 ether);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 coinIn;
        for (uint256 i; i < 2000; ++i) {
            (, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            _warp(1 hours);
        }
        assertLe(coinIn, coin.balanceOf(taker), "setup: affordable");
        (uint256 slice,) = core.exitAuctionQuote();
        assertGt(slice, 0, "setup: a slice is for sale");
        uint256 supply = coin.totalSupply();
        vm.prank(taker);
        core.buybackExit(coinIn);
        assertEq(xt.balanceOf(taker), slice, "buybackExit paid the slice");
        assertEq(core.xToBuyback(), xBuyback - slice, "the exit buyback pot fell by the slice");
        assertEq(coin.totalSupply(), supply - coinIn, "the coin was burned");
    }

    function test_OK_aRetiredCoreStillRunsBothBuybacks() public {
        World memory w = _world();
        _setSuccessor();
        _migrate(1000);
        // the coin buyback burns the buyback pot that stayed
        uint256 retained = core.ethToBuyback();
        assertGt(retained, 0, "setup: the buyback pot stays");
        uint256 supply = coin.totalSupply();
        vm.roll(block.number + 200);
        core.buyback();
        assertLt(coin.totalSupply(), supply, "the buyback did not burn coin");
        assertLt(core.ethToBuyback(), retained, "the buyback pot did not fall");
        // an exit refills the exit buyback pot, which buybackExit sells for coin
        vm.warp(block.timestamp + core.settings().exitAfter);
        core.exitStatement(w.listed);
        uint256 xBuyback = core.xToBuyback();
        assertGt(xBuyback, 0, "setup: the exit buyback pot holds exit token");
        address taker = _user("taker");
        _buyCoin(taker, 20 ether);
        vm.prank(taker);
        coin.approve(address(core), type(uint256).max);
        uint256 coinIn;
        for (uint256 i; i < 2000; ++i) {
            (, coinIn) = core.exitAuctionQuote();
            if (coinIn <= coin.balanceOf(taker)) break;
            _warp(1 hours);
        }
        assertLe(coinIn, coin.balanceOf(taker), "setup: affordable");
        uint256 xBefore = xt.balanceOf(taker);
        vm.prank(taker);
        core.buybackExit(coinIn);
        assertGt(xt.balanceOf(taker), xBefore, "buybackExit paid no exit token");
        assertLt(core.xToBuyback(), xBuyback, "the exit buyback pot did not fall");
    }

    function test_OK_aRetiredCoreStillTakesOwnerCallsAndRescues() public {
        _world();
        _setSuccessor();
        _migrate(1000);
        vm.startPrank(owner);
        core.setRate(core.RATE_START());
        core.addTarget(address(0xA110C));
        core.removeTarget(address(0xA110C));
        vm.stopPrank();
        _setSettings(core.settings());
        // a credit sent straight to the core leaves by rescueNft
        uint256[] memory ids = _credits(seller, 1);
        vm.prank(seller);
        CREDITS.transferFrom(seller, address(core), ids[0]);
        vm.prank(owner);
        core.rescueNft(address(CREDITS), ids[0], owner);
        assertEq(CREDITS.ownerOf(ids[0]), owner, "rescueNft");
        // coin sent by an allowlisted holder leaves by rescueCoin
        vm.prank(owner);
        coin.setAllowed(funder, true);
        vm.prank(funder);
        coin.transfer(address(core), 1_000e18);
        vm.prank(owner);
        core.rescueCoin(funder, 1_000e18);
        assertEq(coin.balanceOf(address(core)), 0, "rescueCoin");
        // a later migrate to another successor
        MigrationSink other = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(other));
        vm.prank(owner);
        core.lockSuccessor();
        _fundPot(1 ether);
        uint256 pot = core.ethPot();
        _migrate(10);
        assertEq(other.ethReceived(), pot, "the later migrate did not move the pot");
        assertTrue(core.retired());
    }

    // ------------------------------------------------------------------ the successor address

    function test_REVERT_theSuccessorIsNotPartOfTheEngine() public {
        _enterPhase2();
        address[8] memory bad = [
            address(core),
            address(house),
            address(feeRouter),
            address(coin),
            address(CREDITS),
            address(STATEMENTS),
            address(mod),
            address(xt)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICore.BadSuccessor.selector, bad[i]));
            vm.prank(owner);
            core.setSuccessor(bad[i]);
        }
        assertEq(core.successor(), address(0), "a refused address was stored");
    }

    // ------------------------------------------------------------------ gas

    function _gasOf(uint256 maxCredits) internal returns (uint256 used) {
        vm.prank(owner);
        uint256 g = gasleft();
        core.migrate(maxCredits);
        used = g - gasleft();
    }

    function test_GAS_migrateEightyCreditsPerPile() public {
        _enterPhase2();
        _fundPot(2 ether);
        _fillEthPile(80);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 1_000_000_000e18);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        assertEq(core.pileSize(Lane.Eth), 80, "setup: eighty eth lane credits");
        assertEq(core.pileSize(Lane.Exit), 80, "setup: eighty exit lane credits");
        _setSuccessor();
        uint256 snap = vm.snapshotState();

        uint256 pots = _gasOf(0);
        vm.revertToState(snap);
        uint256 credits40 = _gasOf(40);
        vm.revertToState(snap);
        uint256 credits80 = _gasOf(80);
        emit log_named_uint("gas: migrate(0), the pots only", pots);
        emit log_named_uint("gas: migrate(40), 40 credits per pile", credits40);
        emit log_named_uint("gas: migrate(80), 80 credits per pile", credits80);
        uint256 perCredit = (credits80 - credits40) / 80;
        emit log_named_uint("gas per credit", perCredit);
        emit log_named_uint("largest maxCredits under 16777216", (16_777_216 - pots) / (2 * perCredit));
        assertLt(credits80, 16_777_216, "80 credits per pile fit the transaction cap");
    }
}
