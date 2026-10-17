// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {MigrationSink} from "./standins/MigrationSink.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {Vm} from "forge-std/Vm.sol";

/// `setSuccessor`, `lockSuccessor` and `migrate` of the Core on the fork: the real Core, Credits, Statements and
/// pool, the stand in balance module and token, and `MigrationSink` as the successor. the first `migrate` retires the Core:
/// six doors refuse with `Retired`, and settling, redemptions, sales of statements, both buybacks and the owner functions work
contract MigrateTest is Fixture {
    MigrationSink internal sink;
    address internal stranger = address(0x5757);

    /// the statements of `_world`: two statements the core holds, one that was bought, and one composed from credits
    /// bought through the balance token bid
    struct World {
        uint256 forRedeem;
        uint256 forSale;
        uint256 sold;
        uint256 balanceBid;
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

    function _composedStatement() internal returns (uint256 sid) {
        _fillEthPile(80);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    function _balanceBidStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(mod), 1_000_000_000e18);
        vm.prank(seller);
        core.sellForBalance(ids);
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    /// pots in both currencies, credits in the pile from both the eth and the balance bid, and one statement of each kind
    function _world() internal returns (World memory w) {
        _enterPhase2();
        _setBalancePool();
        _fundPot(3 ether);
        // the first statement redeems, which fills the balance pots
        _fillBalanceBuyback();
        w.forRedeem = _composedStatement();
        w.forSale = _composedStatement();
        w.sold = _composedStatement();
        _buy(address(0xB2D), w.sold);
        // the proceeds of the sale are booked: half to the pot, half to the coin buyback pot
        w.balanceBid = _balanceBidStatement();
        // credits left in the pile, from the eth bid and the balance bid
        _fillEthPile(7);
        uint256[] memory ids = _credits(seller, 5);
        vm.prank(seller);
        core.sellForBalance(ids);
    }

    function _heldCount() internal view returns (uint256) {
        return core.heldStatements().length;
    }

    // ------------------------------------------------------------------ the owner doors

    // promise: INTEGRATION NoCode on setSuccessor
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

    // promise: INTEGRATION NoSuccessor
    function test_REVERT_migrateNeedsASuccessor() public {
        vm.expectRevert(ICore.NoSuccessor.selector);
        _migrate(10);
        assertFalse(core.retired(), "a refused migrate retired the core");
    }

    // promise: inv 13 the successor lock stays closed
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

    // promise: INTEGRATION OnlyOwner on migrate
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

    // promise: SPEC 1 migrate falls back to a plain send of eth
    /// the record and holder of a statement, as one hash
    /// a successor with a receive function and no `fund` (a Safe) takes the pot by the plain send
    function test_OK_aSuccessorWithoutFundTakesAPlainSend() public {
        _world();
        PlainSuccessor plain = new PlainSuccessor();
        vm.prank(owner);
        core.setSuccessor(address(plain));
        vm.prank(owner);
        core.lockSuccessor();
        uint256 pot = core.ethPot();
        assertGt(pot, 0, "setup: a pot");
        _migrate(100);
        assertEq(address(plain).balance, pot, "the successor got the pot");
        assertEq(core.ethPot(), 0, "ethPot");
        assertTrue(core.retired(), "retired");
    }

    function _fingerprint(uint256 sid) internal view returns (bytes32) {
        (bool held, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
        return keccak256(abi.encode(held, cost, composedAt, STATEMENTS.ownerOf(sid)));
    }

    // promise: SPEC 1 migrate moves ethPot and credits and leaves ethToBuyback and ethRedeemBurn; the balance token stays in the module
    function test_OK_potsAndCreditsMove() public {
        _world();
        _setSuccessor();

        uint256 pot = core.ethPot();
        uint256 buyback = core.ethToBuyback();
        uint256 reserve = core.ethRedeemBurn();
        assertTrue(pot > 0 && buyback > 0, "setup: the eth pots hold something");
        uint256[] memory pileIds = core.pilePage(0, 100);
        assertEq(pileIds.length, 12, "setup: one pile of 7 eth bid plus 5 balance bid credits");
        uint256 balance = address(core).balance;
        assertEq(xt.balanceOf(address(core)), 0, "setup: the core holds no balance token");
        uint256 coinBalance = coin.balanceOf(address(core));

        assertFalse(core.retired(), "setup: not retired");
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.EngineRetired(address(sink));
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), pot, 12);
        _migrate(1000);

        assertTrue(core.retired(), "the first migrate did not retire the core");
        // eth: the sink got the pot, the buyback pot stays, the rest of the balance stays
        assertEq(sink.ethReceived(), pot, "the sink did not get the eth pot");
        assertEq(sink.sends(), 1, "one plain call");
        assertEq(core.ethPot(), 0, "ethPot");
        assertEq(core.ethToBuyback(), buyback, "ethToBuyback stays");
        assertEq(core.ethRedeemBurn(), reserve, "ethRedeemBurn stays");
        assertEq(address(core).balance, balance - pot, "the core balance");
        // the balance token is held by the module, so migrate moves none to the sink
        assertEq(xt.balanceOf(address(sink)), 0, "the balance token did not migrate");
        // the coin stays
        assertEq(coin.balanceOf(address(core)), coinBalance, "the coin moved");
        // credits
        for (uint256 i; i < pileIds.length; ++i) {
            assertEq(CREDITS.ownerOf(pileIds[i]), address(sink), "a credit did not move");
            (bool inPile,,) = core.creditInfo(pileIds[i]);
            assertFalse(inPile, "a moved credit is still in the pile");
        }
        assertEq(core.pileSize(), 0, "pile size");
        assertEq(core.pilePage(0, 1).length, 0, "pile head");
        _solvent();
    }

    // promise: SPEC 1 held statements and their records stay in the Core
    function test_OK_everyHeldStatementStaysAsItWas() public {
        World memory w = _world();
        _setSuccessor();
        uint256[4] memory sids = [w.forRedeem, w.forSale, w.sold, w.balanceBid];
        bytes32[4] memory before;
        for (uint256 i; i < 4; ++i) {
            before[i] = _fingerprint(sids[i]);
        }
        uint256[] memory heldBefore = core.heldStatements();
        assertEq(heldBefore.length, 3, "setup: three statements on the books");
        _migrate(1000);
        for (uint256 i; i < 4; ++i) {
            assertEq(_fingerprint(sids[i]), before[i], "a statement changed");
        }
        uint256[] memory heldAfter = core.heldStatements();
        assertEq(heldAfter.length, heldBefore.length, "the held list changed");
        for (uint256 i; i < heldAfter.length; ++i) {
            assertEq(heldAfter[i], heldBefore[i], "the held order changed");
        }
        assertEq(STATEMENTS.ownerOf(w.forRedeem), address(core), "the eth lane statement left the core");
        assertEq(STATEMENTS.ownerOf(w.forSale), address(core), "the eth lane statement left the core");
        assertEq(STATEMENTS.ownerOf(w.balanceBid), address(core), "the balance bid statement left the core");
        assertEq(STATEMENTS.ownerOf(w.sold), address(0xB2D), "the winner lost the statement");
        assertEq(STATEMENTS.balanceOf(address(sink)), 0, "a statement reached the successor");
    }

    // promise: SPEC 1 a retired Core sells out its statements, a second migrate moves the proceeds
    function test_OK_theOldEngineSellsOutItsStatementsAndASecondMigrateMovesTheProceeds() public {
        World memory w = _world();
        _setSuccessor();
        _migrate(1000);
        uint256 ethBefore = sink.ethReceived();
        assertEq(_heldCount(), 3, "three statements on the books");
        // a statement redeems once its asking price falls to its cost
        _makeEligible(w.forRedeem);
        _makeEligible(w.balanceBid);
        // the pots are empty after the migration: the redemption payment to the caller clamps at the pot
        assertEq(core.ethPot(), 0, "setup: the eth pot is empty");
        vm.fee(composeBasefee);
        vm.txGasPrice(composeBasefee);
        uint256 callerBalance = address(this).balance;
        core.redeemStatement(w.forRedeem);
        core.redeemStatement(w.balanceBid);
        assertEq(core.ethPot(), 0, "the redemption took eth from an empty pot");
        assertEq(address(this).balance, callerBalance, "the caller was paid from an empty pot");
        assertEq(_heldCount(), 1, "the redemptions left one statement on the books");
        assertGt(_moduleHolding(), 0, "the redemption did not fill the module");
        // the remaining statement sells through the controller. the pot share moves in the next call, the buyback
        // share stays
        uint256 buybackBefore = core.ethToBuyback();
        _buy(address(0xB3D), w.forSale);
        assertEq(_heldCount(), 0, "nothing is left on the books");
        uint256 booked = core.ethPot();
        assertGt(booked, 0, "the proceeds were booked");
        assertGt(core.ethToBuyback(), buybackBefore, "the buyback share was booked");
        uint256 buybackStays = core.ethToBuyback();
        _migrate(1000);
        assertEq(sink.ethReceived(), ethBefore + booked, "the second call did not move the new eth");
        assertEq(xt.balanceOf(address(sink)), 0, "the balance token stays in the module");
        assertEq(core.ethPot(), 0, "the pot is zero again");
        assertEq(core.ethToBuyback(), buybackStays, "the buyback pot stays");
        assertEq(STATEMENTS.balanceOf(address(sink)), 0, "a statement reached the successor");
        // a call with nothing left to move does nothing
        uint256 sends = sink.sends();
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), 0, 0);
        _migrate(1000);
        assertEq(sink.sends(), sends, "an empty call sent eth");
        _solvent();
    }

    // promise: SPEC 1 a retired Core burns the ethToBuyback that stayed
    function test_OK_buybackAfterAMigrationBurnsTheRetainedBuybackPot() public {
        // a sale books its buyback share, which stays after the migrate
        uint256 first = _composedStatement();
        _buy(address(0xB1D), first);
        _setSuccessor();
        _migrate(1000);
        uint256 retained = core.ethToBuyback();
        assertGt(retained, 0, "setup: the buyback pot stays after the migrate");
        assertEq(core.ethPot(), 0, "setup: the pot moved");
        uint256 supply = coin.totalSupply();
        vm.roll(block.number + 200);
        core.buyback();
        assertLt(coin.totalSupply(), supply, "the buyback did not burn coin");
        _solvent();
    }

    // promise: INTEGRATION migrate(0) moves the pots only
    function test_OK_aZeroBatchMovesOnlyThePots() public {
        _world();
        _setSuccessor();
        uint256 eth = core.ethPot();
        uint256 held = _heldCount();
        uint256 pileSize = core.pileSize();
        _migrate(0);
        assertEq(sink.ethReceived(), eth);
        assertEq(xt.balanceOf(address(sink)), 0, "no balance token migrates");
        assertEq(core.pileSize(), pileSize, "credits moved with a zero batch");
        assertEq(_heldCount(), held, "statements changed with a zero batch");
    }

    // ------------------------------------------------------------------ a successor that misbehaves

    // promise: INTEGRATION CallFailed on migrate
    function test_REVERT_aSuccessorThatRefusesEthLeavesEverythingInPlace() public {
        _world();
        _setSuccessor();
        sink.setRefuse(true);
        uint256 pot = core.ethPot();
        uint256 held = _heldCount();
        uint256 ethPile = core.pileSize();
        vm.expectRevert(ICore.CallFailed.selector);
        _migrate(100);
        assertFalse(core.retired(), "a failed migrate retired the core");
        assertEq(core.ethPot(), pot, "pot changed");
        assertEq(core.pileSize(), ethPile, "pile changed");
        assertEq(_heldCount(), held, "statements changed");
        // the owner points at another successor
        MigrationSink other = new MigrationSink();
        vm.prank(owner);
        core.setSuccessor(address(other));
        _migrate(100);
        assertGt(other.ethReceived(), 0);
    }

    // promise: INTEGRATION Reentrancy on migrate
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

    // promise: inv 13 retired stays set after the first migrate
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

    // promise: SPEC 1 migrate has no balance token leg: the token is held by the module
    /// migrate moves the eth and the credits and never touches the balance token, which the module holds
    function test_OK_migrateHasNoBalanceTokenLeg() public {
        _world();
        _setSuccessor();
        uint256 pot = core.ethPot();
        uint256 credits = core.pileSize();
        assertEq(xt.balanceOf(address(core)), 0, "the core holds no balance token");
        vm.expectEmit(true, false, false, true, address(core));
        emit ICore.Migrated(address(sink), pot, credits);
        _migrate(1000);
        assertTrue(core.retired(), "migrate retires the core");
        assertEq(sink.ethReceived(), pot, "the eth leg went through");
        assertEq(CREDITS.balanceOf(address(sink)), credits, "the credit leg went through");
        assertEq(xt.balanceOf(address(sink)), 0, "no balance token migrated");
        _solvent();
    }

    // promise: INTEGRATION maxCredits bounds a batch; Retired on compose
    /// a pile that a partial batch leaves behind can be migrated by later calls, and cannot be composed
    function test_OK_aPartialBatchLeavesThePileMigratableAndComposeIsRefused() public {
        _fillEthPile(80);
        assertEq(core.pileSize(), 80, "setup: a full page");
        _setSuccessor();
        _migrate(1);
        assertEq(core.pileSize(), 79, "one credit moved");
        vm.fee(composeBasefee);
        vm.expectRevert(ICore.Retired.selector);
        vm.prank(keeper);
        core.compose();
        assertEq(core.pileSize(), 79, "a refused compose took credits");
        _migrate(40);
        assertEq(core.pileSize(), 39);
        _migrate(1000);
        assertEq(core.pileSize(), 0);
        assertEq(CREDITS.balanceOf(address(core)), 0, "credits left in the core");
        assertEq(CREDITS.balanceOf(address(sink)), 80, "the successor holds every credit");
    }

    // promise: SPEC 1 a retired Core books the fees that still arrive
    function test_OK_aRetiredCoreStillBooksFeesAndSkims() public {
        _fundPot(1 ether);
        _setSuccessor();
        _migrate(1000);
        uint256 retained = core.ethToBuyback();
        assertEq(core.ethPot(), 0, "setup: the pot moved");
        // The launch share is zero. Exercise the phase-two reserve route explicitly after retirement.
        Settings memory cfg = core.settings();
        cfg.feeToRedeemBurnBps = 1_000;
        _setSettings(cfg);
        _buyCoin(funder, 3 ether);
        assertGt(core.ethPot(), 0, "fees were not booked to the pot");
        assertEq(core.ethToBuyback(), retained, "fees reached the buyback pot");
        assertGt(core.ethRedeemBurn(), 0, "fees were not booked to the reserve");
        uint256 pot = core.ethPot();
        vm.deal(address(core), address(core).balance + 1 ether);
        core.book();
        assertEq(
            core.ethPot(),
            pot + 1 ether - uint256(1 ether) * core.settings().feeToRedeemBurnBps / 10_000,
            "the book counted the forced eth"
        );
        _solvent();
    }

    // ------------------------------------------------------------------ the successor address

    // promise: INTEGRATION BadSuccessor
    function test_REVERT_theSuccessorIsNotPartOfTheEngine() public {
        _enterPhase2();
        address[6] memory bad = [
            address(core),
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

    // promise: RUNBOOK a migrate batch of 160 credits fits the transaction cap
    function test_GAS_migrateOneSixtyCredits() public {
        _enterPhase2();
        _setBalancePool();
        _fundPot(2 ether);
        _fillEthPile(80);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(mod), 1_000_000_000e18);
        vm.prank(seller);
        core.sellForBalance(ids);
        assertEq(core.pileSize(), 160, "setup: one pile of 80 eth bid plus 80 balance bid credits");
        _setSuccessor();
        uint256 snap = vm.snapshotState();

        uint256 pots = _gasOf(0);
        vm.revertToState(snap);
        uint256 credits80 = _gasOf(80);
        vm.revertToState(snap);
        uint256 credits160 = _gasOf(160);
        emit log_named_uint("gas: migrate(0), the pots only", pots);
        emit log_named_uint("gas: migrate(80), 80 credits", credits80);
        emit log_named_uint("gas: migrate(160), 160 credits", credits160);
        uint256 perCredit = (credits160 - credits80) / 80;
        emit log_named_uint("gas per credit", perCredit);
        emit log_named_uint("largest maxCredits under 16777216", (16_777_216 - pots) / perCredit);
        assertLt(credits160, 16_777_216, "160 credits fit the transaction cap");
    }
}

/// a successor that takes eth by `receive` only
contract PlainSuccessor {
    receive() external payable {}
}
