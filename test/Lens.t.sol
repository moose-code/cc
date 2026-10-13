// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICoreLens} from "../src/interfaces/ICoreLens.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// `CoreLens` on the fork: the real Core, controller, Credits and Statements. every field of `snapshot` is compared
/// with the direct reads on a populated system, and the pending income with an actual book
contract LensTest is Fixture {
    uint256 internal sidFirst;
    uint256 internal sidSecond;
    uint256 internal sidBalanceBid;

    function _composedStatement() internal returns (uint256 sid) {
        _fillEthPile(80);
        uint256 supply = STATEMENTS.supply();
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    /// a statement composed from credits bought through the balance token bid. one pile, so it is a normal statement
    function _balanceBidStatement() internal returns (uint256 sid) {
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 1_000_000_000e18);
        core.bookBalance();
        vm.prank(seller);
        core.sellForBalance(ids);
        uint256 supply = STATEMENTS.supply();
        vm.prank(keeper);
        core.compose();
        sid = supply + 1;
    }

    /// three held statements, credits in the pile, pots in both currencies and fee eth in the Core above its pots with
    /// the payee share on
    function _populate() internal {
        _enterPhase2();
        _setBalancePool();
        _fundPot(3 ether);
        sidFirst = _composedStatement();
        sidSecond = _composedStatement();
        sidBalanceBid = _balanceBidStatement();
        _fillEthPile(7);
        uint256[] memory ids = _credits(seller, 5);
        vm.prank(seller);
        core.sellForBalance(ids);
        // the first book after the window turns the payee share on, then the Core keeps the next fees unbooked
        _skipToPayeeStart();
        _buyCoin(funder, 2 ether);
        assertTrue(core.payeeOn(), "payee share on");
        autoBook = false;
        _buyCoin(funder, 3 ether);
        assertGt(address(core).balance - _tracked(), 0, "fees unbooked");
        // eth above the booked pots
        vm.deal(address(core), address(core).balance + 0.01 ether);
    }

    function _assertStatementViews(ICoreLens.StatementView[] memory v, uint256 offset) internal view {
        uint256[] memory held = core.heldStatements();
        for (uint256 i; i < v.length; ++i) {
            uint256 sid = held[offset + i];
            ICoreLens.StatementView memory s = v[i];
            assertEq(s.id, sid, "id");
            (, uint256 cost, uint64 composedAt) = core.statementInfo(sid);
            assertEq(s.cost, cost, "cost");
            assertEq(s.composedAt, composedAt, "compose time");
            assertEq(s.askingPrice, ctl.priceOf(sid), "asking price");
        }
    }

    function test_OK_everyFieldEqualsTheDirectReads() public {
        _populate();
        // the asking price has moved off the start price
        _warp(7 hours);
        ICoreLens.Snapshot memory s = lens.snapshot();

        assertEq(s.ethRate, core.ethRate(), "ethRate");
        assertEq(s.ethPrice, core.ethPrice(), "ethPrice");
        assertGe(s.ethPrice, s.ethRate, "the read is the price state or the clamp below it");
        assertEq(s.pileSize, 12, "pile size: 7 eth bid plus 5 balance bid");
        assertEq(s.pileSize, core.pileSize());
        assertEq(s.pileHead, core.pilePage(0, 1)[0]);
        assertTrue(s.pileHead != 0, "head");
        assertFalse(s.pageReady, "12 credits are not a page");

        assertEq(s.ethPot, core.ethPot(), "ethPot");
        assertEq(s.ethToBuyback, core.ethToBuyback(), "ethToBuyback");
        assertEq(s.ethRedeemBurn, core.ethRedeemBurn(), "ethRedeemBurn");
        assertEq(s.balancePot, core.balancePot(), "balancePot");
        assertTrue(s.ethPot != 0 && s.balancePot != 0, "pots populated");
        assertEq(s.pendingIncome, address(core).balance - _tracked(), "pendingIncome");
        assertGe(s.pendingIncome, 0.01 ether, "pendingIncome carries the extra eth");
        assertEq(s.payee, core.payee(), "payee");
        assertEq(s.payeeOwed, core.payeeOwed(), "payeeOwed");
        assertEq(s.payeeOn, core.payeeOn(), "payeeOn");
        assertTrue(s.payeeOn, "payee share on");

        assertEq(s.controller, address(ctl), "controller");
        assertEq(s.successor, core.successor(), "successor");
        assertEq(s.controllerLocked, core.controllerLocked());
        assertEq(s.balanceModuleLocked, core.balanceModuleLocked());
        assertEq(s.adaptersLocked, core.adaptersLocked());
        assertEq(s.successorLocked, core.successorLocked());

        assertEq(s.statements.length, core.heldStatements().length, "statement count");
        assertEq(s.statements.length, 3, "three statements held");
        _assertStatementViews(s.statements, 0);
        for (uint256 i; i < s.statements.length; ++i) {
            ICoreLens.StatementView memory v = s.statements[i];
            assertTrue(v.id == sidFirst || v.id == sidSecond || v.id == sidBalanceBid);
            // every statement sells for eth on the curve, so each has an asking price
            assertGt(v.askingPrice, 0);
        }
    }

    function test_OK_pendingIncomeIsWhatTheNextBookCounts() public {
        _populate();
        ICoreLens.Snapshot memory s = lens.snapshot();
        uint256 owed0 = core.payeeOwed();
        core.book();
        assertEq(core.payeeOwed() - owed0, s.pendingIncome * core.settings().payeePpm / 1_000_000, "the payee share");
        ICoreLens.Snapshot memory after_ = lens.snapshot();
        assertEq(after_.pendingIncome, 0, "nothing left to book");
        assertEq(after_.payeeOwed, core.payeeOwed());
    }

    function test_OK_thePayeeFieldsBeforeTheShare() public {
        // before the payee share starts the whole income is pending and nothing is owed
        autoBook = false;
        _buyCoin(funder, 3 ether);
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertFalse(s.payeeOn);
        assertEq(s.payee, lc.payee);
        assertEq(s.pendingIncome, address(core).balance);
        assertEq(s.payeeOwed, 0);
    }

    function test_OK_theRateIsThePayoutOfOneCredit() public {
        _fundPot(1 ether);
        uint256[] memory ids = _credits(seller, 4);
        uint256 quoted = lens.snapshot().ethRate;
        assertEq(quoted, core.ethRate());
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        assertEq(seller.balance - before, quoted, "the payout equals the quote");
    }

    function test_OK_aFullPageIsReady() public {
        _fillEthPile(80);
        assertTrue(lens.snapshot().pageReady, "80 credits make a page");
    }

    function test_OK_statementsPageEqualsTheSnapshotSlices() public {
        _enterPhase2();
        _fundPot(3 ether);
        sidFirst = _composedStatement();
        sidSecond = _composedStatement();
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.statements.length, 2);
        ICoreLens.StatementView[] memory p0 = lens.statementsPage(0, 1);
        ICoreLens.StatementView[] memory p1 = lens.statementsPage(1, 5);
        assertEq(p0.length, 1);
        assertEq(p1.length, 1);
        assertEq(p0[0].id, s.statements[0].id);
        assertEq(p1[0].id, s.statements[1].id);
        assertEq(p1[0].askingPrice, s.statements[1].askingPrice);
        assertEq(lens.statementsPage(2, 5).length, 0, "past the end");
        assertEq(lens.statementsPage(9, type(uint256).max).length, 0, "start past the end");
        assertEq(lens.statementsPage(0, type(uint256).max).length, 2, "a huge count is cut to the list");
        _assertStatementViews(p1, 1);
    }

    /// the cost of `snapshot` per held statement, to size a keeper's call. logged, with a bound
    function test_GAS_snapshotPerStatement() public {
        _enterPhase2();
        _fundPot(3 ether);
        uint256 g = gasleft();
        lens.snapshot();
        uint256 empty = g - gasleft();
        sidFirst = _composedStatement();
        sidSecond = _composedStatement();
        g = gasleft();
        lens.snapshot();
        uint256 two = g - gasleft();
        emit log_named_uint("snapshot gas, no statements", empty);
        emit log_named_uint("snapshot gas, two statements", two);
        emit log_named_uint("snapshot gas per statement", (two - empty) / 2);
        assertLt(empty, 300_000, "snapshot without statements");
        assertLt((two - empty) / 2, 80_000, "per statement");
    }

    /// the asking price of a held statement is the controller price, and a sold statement is no longer listed
    function test_OK_askingPriceIsTheControllerPriceOfHeldStatements() public {
        _fundPot(3 ether);
        uint256 sold = _composedStatement();
        _buy(address(0xB2D), sold);
        uint256 first = _composedStatement();
        _warp(2 hours);
        uint256 second = _composedStatement();
        ICoreLens.StatementView[] memory v = lens.snapshot().statements;
        assertEq(v.length, 2, "the sold statement left the list");
        for (uint256 i; i < 2; ++i) {
            assertTrue(v[i].id == first || v[i].id == second);
            assertEq(v[i].askingPrice, ctl.priceOf(v[i].id), "the controller price");
            assertGt(v[i].askingPrice, 0);
        }
        // in fractions of each statement's reference (the age curve), the older statement is further down the curve
        assertLt(
            ctl.priceOf(first) * 1e18 / ctl.referenceOf(first),
            ctl.priceOf(second) * 1e18 / ctl.referenceOf(second),
            "older is cheaper"
        );
    }

    /// the lens requires the answer size of `nextPage` that the Core requires, so both agree on a short answer
    function test_OK_aShortNextPageAnswerIsNotReadyForTheLensAndForCompose() public {
        _fillEthPile(80);
        uint256[] memory page = core.pilePage(0, 80);
        assertTrue(lens.snapshot().pageReady, "the real controller answers ready");
        vm.mockCall(address(ctl), abi.encodeWithSelector(ctl.nextPage.selector), abi.encode(uint256(1)));
        assertFalse(lens.snapshot().pageReady, "one word is a short answer");
        vm.expectRevert(ICore.NotReady.selector);
        vm.prank(keeper);
        core.compose();
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page[i];
        }
        vm.mockCall(address(ctl), abi.encodeWithSelector(ctl.nextPage.selector), abi.encode(uint256(1), ids, uint256(0)));
        assertTrue(lens.snapshot().pageReady, "the full size answer is ready");
        vm.clearMockedCalls();
    }

    function test_OK_thePointersAndTheControllerFollow() public {
        assertEq(lens.CORE(), address(core));
        assertEq(lens.CREDITS(), address(CREDITS));
        assertEq(lens.STATEMENTS(), address(STATEMENTS));
        assertEq(lens.controller(), address(ctl));
        // a controller replaced by the owner is followed, and one without code does not break the snapshot
        _setController(address(0xC0DE));
        assertEq(lens.controller(), address(0xC0DE));
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.controller, address(0xC0DE));
        assertFalse(s.pageReady);
    }

    /// the lens forwards enough gas for the controller's two bounded module reads, so a module that burns most of the
    /// read budget in unitPerPoint gives the same creditPrice through the lens as a direct controller read
    function test_OK_creditPriceThroughTheLensSurvivesAGasBurningModule() public {
        _enterPhase2();
        _setBalancePool();
        uint256[] memory ids = _fillEthPile(1);
        vm.prank(owner);
        ctl.setCreditSaleOn(true);
        mod.setBurnUnitGas(190_000);
        uint256 direct = ctl.creditPrice(ids[0]);
        assertGt(direct, 0, "the controller prices the credit");
        assertEq(lens.creditPriceOf(ids[0]), direct, "the lens answer equals the controller through a gas burning module");
    }

    function test_OK_theSnapshotReadsAnEmptySystem() public view {
        ICoreLens.Snapshot memory s = lens.snapshot();
        assertEq(s.ethRate, core.ethRate());
        assertEq(s.statements.length, 0);
        assertEq(s.pileSize, 0);
        assertEq(s.pileHead, 0);
        assertEq(s.successor, address(0));
    }
}
