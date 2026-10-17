// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {Prod} from "./utils/Prod.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Sale, CreditSale, Settings, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Halving} from "../src/lib/Halving.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {SellingController, ReentrantBuyer, RefundRefuser} from "./attackers/SaleAttackers.sol";
import {StatementInfoStub} from "./standins/StatementInfoStub.sol";

/// the sale controller on the live fork: the asking price curve, the hard floor of the core, `buy` through `sellTo`,
/// the controller's own settings and its anchor. real Core, ControllerV1, Statements. the doubles are the scripted and
/// the attacker controllers only
abstract contract SaleBase is Fixture {
    uint256 internal constant H = 1 hours;

    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (, cost,) = core.statementInfo(sid);
    }

    /// the price reference of statement `sid`: the larger of its cost and `valueOf(rating)`, computed from the parts
    function _reference(uint256 sid) internal view returns (uint256 priceReference) {
        priceReference = _cost(sid);
        uint256 value = ctl.valueOf(core.ratingOf(sid));
        if (value > priceReference) priceReference = value;
    }

    function _composedAt(uint256 sid) internal view returns (uint64 at) {
        (,, at) = core.statementInfo(sid);
    }

    /// moves the clock to `secs` after the statement was composed
    function _age(uint256 sid, uint256 secs) internal {
        vm.warp(_composedAt(sid) + secs);
    }

    /// sets the six sale numbers in one call. the floor is the core `saleFloorBps`
    function _saleSettings(uint16 markup, uint32 cap, uint16 decayH, uint16 floor_) internal {
        _floorBps(floor_);
        Sale memory s = _sale();
        (s.markupBps, s.startCapBps, s.decayHours) = (markup, cap, decayH);
        vm.prank(owner);
        ctl.setSale(s);
    }

    function _anchor(uint32 bps) internal {
        vm.prank(owner);
        ctl.setAnchorBps(bps);
    }

    /// the asking price in wei at `age` seconds: `start` bps of `cost` falls in a straight line to `floor_` bps over
    /// `decayH` hours, then rests. mirrors `ControllerV1._ask`
    function _curve(uint256 cost, uint256 start, uint256 floor_, uint256 decayH, uint256 age)
        internal
        pure
        returns (uint256)
    {
        uint256 span = decayH * 3600;
        uint256 n;
        if (start <= floor_ || age >= span) {
            n = floor_;
        } else {
            n = start - (start - floor_) * age / span;
        }
        return cost * n / 10_000;
    }

    /// the launch curve: 150 percent of the reference falling in a straight line to the floor over `decayHours`
    function _launch(uint256 cost, uint256 age) internal view returns (uint256) {
        return _curve(cost, ctl.startBps(), core.settings().saleFloorBps, ctl.decayHours(), age);
    }

    function _floorBps(uint16 bps) internal {
        Settings memory s = core.settings();
        s.saleFloorBps = bps;
        _setSettings(s);
    }

    /// decision 124 keeps the floor at or below the start. drops the floor to its minimum, moves the start
    /// (`markupBps`), then sets the floor, so every intermediate state holds floor at or below the start
    function _markupThenFloor(uint16 markup, uint16 floor) internal {
        _floorBps(1_000);
        Sale memory sale = _sale();
        sale.markupBps = markup;
        if (sale.startCapBps < markup) sale.startCapBps = markup;
        vm.prank(owner);
        ctl.setSale(sale);
        _floorBps(floor);
    }

    function _buybackBps(uint16 bps) internal {
        Settings memory s = core.settings();
        s.saleToBuybackBps = bps;
        _setSettings(s);
    }

    /// a second statement, composed after the first. returns its id
    function _another() internal returns (uint256 sid) {
        _fillEthPile(80);
        vm.fee(composeBasefee);
        vm.prank(keeper);
        core.compose();
        sid = STATEMENTS.supply();
    }

    /// the artist and operator cuts of a sale payment and the rest after them
    function _saleCuts(uint256 pay) internal view returns (uint256 toArtist, uint256 toOperator, uint256 rest) {
        toArtist = pay * core.settings().saleToArtistBps / 10_000;
        toOperator = pay * core.settings().saleToOperatorBps / 10_000;
        rest = pay - toArtist - toOperator;
    }

    /// `who` pays the asking price `price`
    function _pay(address who, uint256 sid, uint256 price) internal {
        _payExtra(who, sid, price, 0);
    }

    /// `who` pays the asking price and `extra` on top
    function _payExtra(address who, uint256 sid, uint256 price, uint256 extra) internal {
        uint256 value = price + extra;
        vm.deal(who, who.balance + value);
        vm.prank(who);
        ctl.buy{value: value}(sid);
    }

    function _held(uint256 sid) internal view returns (bool found) {
        uint256[] memory h = core.heldStatements();
        for (uint256 i; i < h.length; ++i) {
            if (h[i] == sid) return true;
        }
    }

    function _recordedBook() internal view returns (uint256 pot, uint256 bb, uint256 bal) {
        return (core.ethPot(), core.ethToBuyback(), address(core).balance);
    }

    /// pins the reference to cost for the curve, anchor and decay suites, which assert the launch "settle at cost"
    /// guarantee in bps of cost. the reference is `max(cost, valueOf(rating))`. the statement cost is recorded at the
    /// opening rate, then the floor rate is dropped far below it, so the rate term `floorRate * rating / RATE_SCORE`
    /// stays under cost and the reference equals cost
    function _pinReferenceToCost() internal {
        // no drop within a bucket (`dropFloorBps` 10,000) and the rate capped at the opening rate, so a page's credits
        // all record the same rate: the cost equals the rate term `floorRate * rating / RATE_SCORE` and the reference
        // ties to cost
        Settings memory s = core.settings();
        s.rateCap = uint64(OPEN_RATE);
        s.dropFloorBps = 10_000;
        _setSettings(s);
    }
}

/// the linear curve tests. the launch sale holds the floor at 100 percent of cost, so the price falls
/// from its start to cost and stays there. these tests exercise the slope of the line, so setUp sets `saleFloorBps` to
/// 7_500 through the owner setter. the launch curve itself is `SaleLaunchCurveTest`
abstract contract SaleShapeBase is SaleBase {
    /// the shape, buy, decay and anchor suites run the 12 hour line and the anchor fraction 5,000 they were written for
    /// (the launch before decision 154); the launch curve of 4 hours and the anchor off have their own tests
    function setUp() public virtual override {
        super.setUp();
        _pinReferenceToCost();
        _floorBps(7_500);
        Sale memory s = _sale();
        (s.decayHours, s.anchorMoveBps) = (12, 5_000);
        vm.prank(owner);
        ctl.setSale(s);
    }
}

/// the curve at the launch values: the floor at 100 percent of cost
contract SaleLaunchCurveTest is SaleBase {
    function setUp() public override {
        super.setUp();
        _pinReferenceToCost();
    }

    // promise: SPEC 1 launch curve falls from the start price to the statement reference and rests there
    function test_launchCurve_startsAtStartFallsToCostAndStaysAtCost() public {
        assertEq(ctl.decayHours(), 4, "decay hours at launch");
        assertEq(ctl.anchorMoveBps(), 0, "the anchor is off at launch");
        assertEq(core.settings().saleFloorBps, 10_000, "floor at launch");
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256 start = cost * 15_000 / 10_000;
        uint256[8] memory t = [uint256(0), 1, 2 * H, 4 * H - 1, 4 * H, 4 * H + 1, 100 * H, 100_000 * H];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            uint256 ask = ctl.priceOf(sid);
            assertEq(ask, _curve(cost, 15_000, 10_000, 4, t[i]), "closed form at launch values");
            assertGe(ask, cost, "never below the floor (cost)");
            assertLe(ask, start, "never above the start");
        }
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), start, "starts at 150 percent");
        _age(sid, 2 * H);
        assertEq(ctl.priceOf(sid), cost * 12_500 / 10_000, "halfway through the window it is 125 percent");
        _age(sid, 4 * H);
        assertEq(ctl.priceOf(sid), cost, "reaches cost (the floor) at hour 4");
        _age(sid, 4 * H - 1);
        assertGt(ctl.priceOf(sid), cost, "one second before it is above cost");
        _age(sid, 5000 * H);
        assertEq(ctl.priceOf(sid), cost, "stays at cost");
    }
}

contract SaleCurveTest is SaleShapeBase {
    // promise: SPEC 1 a statement sells at or above saleFloorBps of its reference (inv 3)
    /// the quote is never below `saleFloorBps` of the reference, whatever the age and the floor setting
    function test_curve_priceOfStaysAtOrAboveTheFloor() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint16[3] memory hard = [uint16(1_000), 7_500, 12_000];
        uint256[5] memory t = [uint256(0), 1, 6 * H, 12 * H, 5000 * H];
        for (uint256 i; i < hard.length; ++i) {
            _floorBps(hard[i]);
            for (uint256 j; j < t.length; ++j) {
                _age(sid, t[j]);
                uint256 ask = _curve(cost, 15_000, hard[i], 12, t[j]);
                uint256 floor = cost * hard[i] / 10_000;
                assertEq(ctl.priceOf(sid), ask, "the curve with the floor from the setting");
                assertGe(ctl.priceOf(sid), floor);
            }
        }
    }

    // promise: INTEGRATION NotForSale
    function test_curve_priceOfRefusesWhatIsNotForSale() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        assertGt(sid, 0, "a statement was composed");
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(sid + 100);
    }
}

contract SaleFloorTest is SaleBase {
    // promise: SPEC 1 a raise of saleFloorBps reaches every held statement at once (decision 124 raises the start with it)
    /// the ask is a bps share of the reference max(cost, valueOf(rating)). the floor is read live: a floor raised to the
    /// start lifts the ask of a held statement at once, a lowered floor gives way to the curve again, and the buy pays
    /// the lifted price
    function test_floor_followsTheSettingAtOnce() public {
        uint256 sid = _composeOnce().sid;
        uint256 priceReference = _reference(sid);
        assertEq(ctl.priceOf(sid), priceReference * 15_000 / 10_000);
        _markupThenFloor(20_000, 20_000);
        assertEq(ctl.priceOf(sid), priceReference * 20_000 / 10_000, "a raised floor reaches the held statement");
        _markupThenFloor(15_000, 1_000);
        assertEq(ctl.priceOf(sid), priceReference * 15_000 / 10_000, "a lowered floor gives way to the curve");
        _markupThenFloor(20_000, 20_000);
        address buyer = address(0xB0B);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: priceReference * 15_000 / 10_000}(sid);
        assertEq(_buy(buyer, sid), priceReference * 20_000 / 10_000);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }
}

contract SaleBuyTest is SaleShapeBase {
    address internal buyer = address(0xB0B);

    function _buyAt(uint256 age) internal returns (uint256 sid, uint256 price) {
        sid = _composeOnce().sid;
        _age(sid, age);
        price = ctl.priceOf(sid);
    }

    // promise: SPEC 1 buy sells through sellTo and books the payment at once; INTEGRATION buy split
    function test_buy_exactPriceSplitAndOwnership() public {
        uint16[4] memory shares = [uint16(0), 5_000, 10_000, 3_333];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            _buybackBps(shares[i]);
            (uint256 sid, uint256 price) = _buyAt(10 * H);
            assertEq(
                price, _cost(sid) * 8_750 / 10_000, "10 hours down the 12 hour line (150 to 75 percent): 87.5 percent"
            );
            (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
            uint256 n = core.heldStatements().length;
            (uint256 toArtist, uint256 toOperator, uint256 rest) = _saleCuts(price);
            uint256 toBuyback = rest * shares[i] / 10_000;
            vm.expectEmit(address(core));
            emit ICore.StatementSoldTo(sid, buyer, price, toBuyback, toArtist, toOperator);
            vm.expectEmit(address(ctl));
            emit IControllerV1.Bought(sid, buyer, price);
            _pay(buyer, sid, price);
            assertEq(buyer.balance, 0, "exact payment, nothing back");
            assertEq(STATEMENTS.ownerOf(sid), buyer);
            assertEq(address(core).balance - bal0, rest, "the rest stays after the cuts");
            assertEq(core.ethToBuyback() - bb0, toBuyback);
            assertEq(core.ethPot() - pot0, rest - toBuyback);
            assertEq(address(ctl).balance, 0, "the controller holds no eth");
            (bool held,,) = core.statementInfo(sid);
            assertFalse(held, "the core record is cleared");
            assertEq(core.heldStatements().length, n - 1);
            assertFalse(_held(sid));
            _solvent();
            vm.revertToState(snap);
        }
    }

    // promise: INTEGRATION buy refunds the excess last
    function test_buy_refundsTheExcess() public {
        (uint256 sid, uint256 price) = _buyAt(0);
        _payExtra(buyer, sid, price, 3 ether);
        assertEq(buyer.balance, 3 ether, "the excess came back");
        assertEq(address(ctl).balance, 0, "the controller holds no eth");
    }

    // promise: INTEGRATION Underpaid
    function test_buy_underpayRevertsAndChangesNothing() public {
        (uint256 sid, uint256 price) = _buyAt(0);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: price - 1}(sid);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy(sid);
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
    }
}

contract SaleSellToTest is SaleBase {
    SellingController internal sc;
    address internal buyer = address(0xB0B);

    function _install() internal {
        sc = new SellingController(core);
        _setController(address(sc));
    }

    function _floorOf(uint256 sid) internal view returns (uint256) {
        return _cost(sid) * core.settings().saleFloorBps / 10_000;
    }

    // promise: INTEGRATION OnlyController
    function test_sellTo_onlyTheCurrentController() public {
        uint256 sid = _composeOnce().sid;
        vm.deal(address(this), 100 ether);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, buyer);
        vm.prank(owner);
        vm.deal(owner, 100 ether);
        vm.expectRevert(ICore.OnlyController.selector);
        core.sellTo{value: 10 ether}(sid, buyer);
        // the first controller has no way to call it except `buy`, and after it is replaced `buy` fails too
        _install();
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(ICore.OnlyController.selector);
        ctl.buy{value: 100 ether}(sid);
        vm.deal(address(sc), 100 ether);
        sc.sell{value: _floorOf(sid)}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    // promise: INTEGRATION BelowFloor; SPEC 1 hard floor (inv 3)
    function test_sellTo_belowTheHardFloorRevertsAtTheFloorClears() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 floor = _floorOf(sid);
        vm.expectRevert(ICore.BelowFloor.selector);
        sc.sell{value: floor - 1}(sid, buyer);
        vm.expectRevert(ICore.BelowFloor.selector);
        sc.sell{value: 0}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        uint256 scBal = address(sc).balance;
        (uint256 toArtist, uint256 toOperator, uint256 rest) = _saleCuts(floor);
        uint256 toBuyback = rest * core.settings().saleToBuybackBps / 10_000;
        vm.expectEmit(address(core));
        emit ICore.StatementSoldTo(sid, buyer, floor, toBuyback, toArtist, toOperator);
        sc.sell{value: floor}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertEq(address(core).balance - bal0, rest, "the rest stays after the cuts");
        assertEq(core.ethToBuyback() - bb0, toBuyback);
        assertEq(core.ethPot() - pot0, rest - toBuyback);
        assertEq(address(sc).balance, scBal, "the controller keeps nothing");
        _solvent();
    }

    // promise: SPEC 4 sellTo books the payment less the cuts (inv 5, inv 18)
    /// the payment less the artist and operator cuts is booked, an overpayment included: the core has no refund logic
    function test_sellTo_booksEverythingItIsPaid() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 pay = _floorOf(sid) * 5;
        _buybackBps(2_500);
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        sc.sell{value: pay}(sid, buyer);
        (,, uint256 rest) = _saleCuts(pay);
        assertEq(core.ethToBuyback() - bb0, rest * 2_500 / 10_000);
        assertEq(core.ethPot() - pot0, rest - rest * 2_500 / 10_000);
    }

    // promise: INTEGRATION NotForSale
    function test_sellTo_unknownAndSoldRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        _install();
        vm.expectRevert(ICore.NotForSale.selector);
        sc.sell{value: 100 ether}(sid + 1000, buyer);
        // a statement that was sold has no record any more
        sc.sell{value: _floorOf(sid)}(sid, buyer);
        vm.expectRevert(ICore.NotForSale.selector);
        sc.sell{value: 100 ether}(sid, buyer);
    }

    // ------------------------------------------------------------------ reentrancy

    // promise: INTEGRATION Reentrancy on the buy refund
    function test_reenter_theBuyersRefundCannotReachAnyDoorTwice() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        ReentrantBuyer rb = new ReentrantBuyer(ctl, core);
        rb.setOther(b);
        uint256 price = ctl.priceOf(a);
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        vm.deal(address(this), price + 2 ether);
        uint256 pre = address(rb).balance;
        rb.buy{value: price + 2 ether}(a);
        assertEq(STATEMENTS.ownerOf(a), address(rb), "the buy went through");
        assertEq(address(rb).balance - pre, 2 ether, "and the refund landed");
        assertEq(rb.reentries(), 1);
        assertTrue(rb.buyBlocked(), "a second buy from the refund is refused");
        assertEq(rb.buySel(), IControllerV1.Reentrant.selector);
        assertTrue(rb.sellBlocked(), "sellTo is the controller's alone");
        assertTrue(rb.redeemBlocked());
        assertEq(STATEMENTS.ownerOf(b), address(core), "the other statement is untouched");
        (,, uint256 rest) = _saleCuts(price);
        assertEq(core.ethPot() - pot0 + core.ethToBuyback() - bb0, rest, "the rest after the cuts booked exactly once");
        _solvent();
    }

    // promise: INTEGRATION buy refunds the excess last
    function test_reenter_aBuyerThatRefusesTheRefundCanOnlyPayExactly() public {
        uint256 sid = _composeOnce().sid;
        RefundRefuser rr = new RefundRefuser(ctl);
        uint256 gross = ctl.priceOf(sid);
        vm.deal(address(rr), gross + 1 ether);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        vm.expectRevert();
        rr.buy{value: gross + 1 ether}(sid);
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "the failed buy changed nothing");
        rr.buy{value: gross}(sid);
        assertEq(STATEMENTS.ownerOf(sid), address(rr));
    }
}

contract SaleSettingsTest is SaleBase {
    function _fresh() internal view returns (Sale memory) {
        return Sale({
            markupBps: lc.sale.markupBps,
            startCapBps: lc.sale.startCapBps,
            decayHours: lc.sale.decayHours,
            anchorHalfLife: lc.sale.anchorHalfLife,
            anchorMinCost: lc.sale.anchorMinCost,
            anchorMoveBps: lc.sale.anchorMoveBps
        });
    }

    function _bad(bytes32 field) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IControllerV1.BadSetting.selector, field);
    }

    // promise: SPEC 2 sale settings at launch
    function test_settings_launchValues() public view {
        assertEq(lc.sale.markupBps, 15_000);
        assertEq(lc.sale.startCapBps, 100_000);
        assertEq(lc.sale.decayHours, 4);
        assertEq(lc.sale.anchorHalfLife, 7 days);
        assertEq(lc.sale.anchorMinCost, 0.1 ether);
        assertEq(lc.sale.anchorMoveBps, 0);
        assertEq(abi.encode(Mainnet.defaultSale()), abi.encode(lc.sale), "the launch sale");
        assertEq(ctl.markupBps(), 15_000);
        assertEq(ctl.startCapBps(), 100_000);
        assertEq(ctl.decayHours(), 4);
        assertEq(core.settings().saleFloorBps, 10_000);
        assertEq(core.settings().saleToArtistBps, 250);
        assertEq(core.settings().saleToOperatorBps, 50);
        assertEq(core.artist(), creator);
        assertEq(ctl.anchorHalfLife(), 7 days);
        assertEq(ctl.anchorMinCost(), 0.1 ether);
        assertEq(ctl.anchorMoveBps(), 0);
        assertEq(ctl.anchorBps(), 10_000, "the anchor starts at the cost");
        assertEq(ctl.storedAnchorBps(), 10_000);
        assertEq(ctl.anchorTime(), block.timestamp);
        assertEq(ctl.startBps(), 15_000);
    }

    /// every upper edge of the sale settings, and every lower edge
    function _hi() internal pure returns (Sale memory) {
        return Sale(type(uint16).max, type(uint32).max, type(uint16).max, type(uint32).max, type(uint128).max, 10_000);
    }

    function _lo() internal pure returns (Sale memory) {
        return Sale(10_000, 10_000, 1, 1, 0, 0);
    }

    function _saleBad(Sale memory s, bytes32 field) internal {
        vm.expectRevert(_bad(field));
        ctl.setSale(s);
    }

    function _creditBad(CreditSale memory c, bytes32 field) internal {
        vm.expectRevert(_bad(field));
        ctl.setCredit(c);
    }

    // promise: sale setters accept typed extrema, preserve their ordering and reject zero divisors
    function test_settings_boundsOfEverySetter() public {
        uint256 sid = _composeOnce().sid;
        uint256 ref = ctl.referenceOf(sid);
        vm.startPrank(owner);
        ctl.setSale(_hi());
        ctl.setAnchorBps(type(uint32).max);
        assertEq(ctl.startBps(), type(uint32).max, "the start cap clamps maximum markup times anchor");
        assertEq(ctl.priceOf(sid), ref * type(uint32).max / 10_000, "max settings still price a real statement");
        assertEq(ctl.anchorMinCost(), type(uint128).max);
        assertEq(ctl.anchorHalfLife(), type(uint32).max);
        assertEq(ctl.markupBps(), type(uint16).max);
        assertEq(ctl.decayHours(), type(uint16).max);
        assertEq(ctl.anchorMoveBps(), 10_000);
        ctl.setSale(_lo());
        assertEq(ctl.anchorBps(), 10_000, "lowering the cap clamps the live anchor");
        assertEq(ctl.priceOf(sid), ref, "minimum valid settings still price a real statement");
        Sale memory s = _lo();
        s.markupBps = 9_999;
        _saleBad(s, "markupBps");
        s = _lo();
        s.startCapBps = s.markupBps - 1;
        _saleBad(s, "startCapBps");
        s = _lo();
        s.decayHours = 0;
        _saleBad(s, "decayHours");
        s = _lo();
        s.anchorHalfLife = 0;
        _saleBad(s, "anchorHalfLife");
        s = _lo();
        s.anchorMoveBps = 10_001;
        _saleBad(s, "anchorMoveBps");
        vm.expectRevert(_bad("anchorBps"));
        ctl.setAnchorBps(9_999);
        vm.expectRevert(_bad("anchorBps"));
        ctl.setAnchorBps(10_001);
        vm.stopPrank();
    }

    // promise: SPEC 1 every economic number is an owner setting, effective at once
    function test_settings_eventsAndValues() public {
        Sale memory s = Sale(12_000, 150_000, 24, 3 days, 0.25 ether, 5_000);
        CreditSale memory c = _creditSale();
        vm.startPrank(owner);
        vm.expectEmit(address(ctl));
        emit IControllerV1.SaleSet(s);
        ctl.setSale(s);
        vm.expectEmit(address(ctl));
        emit IControllerV1.CreditSaleSet(c);
        ctl.setCredit(c);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorBpsSet(11_000);
        ctl.setAnchorBps(11_000);
        vm.stopPrank();
        assertEq(ctl.markupBps(), 12_000);
        assertEq(ctl.startCapBps(), 150_000);
        assertEq(ctl.decayHours(), 24);
        assertEq(ctl.anchorBps(), 11_000);
        assertEq(ctl.anchorHalfLife(), 3 days);
        assertEq(ctl.anchorMinCost(), 0.25 ether);
        assertEq(ctl.startBps(), 13_200);
    }

    // promise: INTEGRATION OnlyOwner on the controller setters
    /// only the live owner of the core: not the deployer, not a keeper, not the controller itself
    function test_settings_onlyTheCoreOwner() public {
        Sale memory s = _sale();
        s.markupBps = 12_000;
        CreditSale memory c = _creditSale();
        address[4] memory who = [deployer, keeper, address(ctl), address(0x5757)];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setSale(s);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setCredit(c);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setAnchorBps(11_000);
            vm.stopPrank();
        }
        assertEq(ctl.anchorHalfLife(), 7 days);
        assertEq(ctl.anchorMinCost(), 0.1 ether);
        assertEq(ctl.anchorMoveBps(), 0);
        assertEq(ctl.markupBps(), 15_000);
        assertEq(ctl.anchorBps(), 10_000);
    }

    // promise: controller construction enforces divisors and ordering, accepting every typed upper edge
    function test_settings_constructorBounds() public {
        Sale memory s = _fresh();
        s.markupBps = 9_999;
        vm.expectRevert(_bad("markupBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.startCapBps = s.markupBps - 1;
        vm.expectRevert(_bad("startCapBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.decayHours = 0;
        vm.expectRevert(_bad("decayHours"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.anchorHalfLife = 0;
        vm.expectRevert(_bad("anchorHalfLife"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.anchorMoveBps = 10_001;
        vm.expectRevert(_bad("anchorMoveBps"));
        Prod.newController(address(core), s);
        IControllerV1 c = Prod.newController(address(core), _hi());
        assertEq(c.anchorBps(), 10_000);
        assertEq(c.anchorHalfLife(), type(uint32).max);
        assertEq(c.markupBps(), type(uint16).max);
        assertEq(c.startCapBps(), type(uint32).max);
        assertEq(c.decayHours(), type(uint16).max);
        assertEq(c.anchorMinCost(), type(uint128).max);
        assertEq(c.anchorMoveBps(), 10_000);
        c = Prod.newController(address(core), _lo());
        assertEq(c.anchorHalfLife(), 1);
        assertEq(c.anchorMinCost(), 0);
        assertEq(c.anchorMoveBps(), 0);
    }
}

contract SaleAnchorTest is SaleShapeBase {
    address internal buyer = address(0xB0B);

    /// a page at the fixture rate costs under the launch `anchorMinCost`. the anchor tests run with the minimum at 0 and
    /// the tests of the minimum set it
    function setUp() public override {
        super.setUp();
        _setAnchorMinCost(0);
    }

    function _composeN(uint256 n) internal returns (uint256[] memory sids) {
        sids = new uint256[](n);
        sids[0] = _composeOnce().sid;
        for (uint256 i = 1; i < n; ++i) {
            sids[i] = _another();
        }
    }

    /// buys `sid` at its compose time, so the price is the start price. returns the price and the cost of the statement
    function _buyAtStart(uint256 sid) internal returns (uint256 price, uint256 cost) {
        _age(sid, 0);
        cost = _cost(sid);
        price = ctl.priceOf(sid);
        _pay(buyer, sid, price);
    }

    /// the number of `AnchorMoved` logs of the controller in `logs`
    function _moved(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(ctl) && logs[i].topics[0] == IControllerV1.AnchorMoved.selector) ++n;
        }
    }

    // promise: SPEC 1 anchorMinCost: dust statements leave the anchor
    /// the review of d77b82c (F1): with an empty pot the engine pays 1 wei per credit, so a statement of about 80 wei is
    /// composed and bought at its start price. four rounds leave the anchor, its time and the fresh start price unchanged
    function test_anchor_dustStatementsLeaveTheAnchor() public {
        // a page costs at most a page at the capped fill rate, under this minimum, so every round is dust
        _setAnchorMinCost(0.2 ether);
        assertEq(core.ethPot(), 0, "the pot is empty");
        address attacker = address(0xA77);
        uint256 t0 = ctl.anchorTime();
        for (uint256 r; r < 4; ++r) {
            uint256[] memory ids = _credits(attacker, 80);
            for (uint256 i; i < 80; ++i) {
                // two wei: the bid's room is the pot over 1 + the royalty (decision 163), so a 2 wei pot reads a 1 wei bid
                vm.deal(attacker, attacker.balance + 2);
                vm.prank(attacker);
                core.fund{value: 2}();
                // refScore set to this credit's score, so the pot reads a 1 wei bid for it (score / refScore is 1)
                _unitScore(ids[i]);
                uint256[] memory one = new uint256[](1);
                one[0] = ids[i];
                vm.prank(attacker);
                core.sellForEth(one);
            }
            vm.fee(composeBasefee);
            vm.prank(keeper);
            core.compose();
            uint256 sid = STATEMENTS.supply();
            assertLt(_cost(sid), ctl.anchorMinCost(), "the statement costs less than the minimum");
            uint256 price = ctl.priceOf(sid);
            // a low-cost statement's cost is below the rate term, so the reference is the rate term and the start price
            // is 150 percent of it, not of the cost. the buy at this price funds the pot, so later rounds cost a page
            // at the capped rate rather than 1 wei each, still under the minimum
            assertEq(price, ctl.referenceOf(sid) * 15_000 / 10_000, "the start price");
            vm.recordLogs();
            _pay(attacker, sid, price);
            assertEq(_moved(vm.getRecordedLogs()), 0, "no AnchorMoved");
            assertEq(STATEMENTS.ownerOf(sid), attacker, "the buy completed");
            assertEq(ctl.anchorBps(), 10_000);
            assertEq(ctl.storedAnchorBps(), 10_000);
            assertEq(ctl.anchorTime(), t0, "no checkpoint");
            assertEq(ctl.startBps(), 15_000, "a fresh statement still starts at 150 percent of cost");
        }
    }

    // promise: SPEC 1 sales at the floor leave the anchor
    /// the review sequence: four sales at the start price raise the anchor to 24_413, then two sales at the floor leave
    /// the anchor, its time and the start price of a held statement where they were
    function test_anchor_floorSalesDoNotDragTheAnchor() public {
        uint256[] memory sids = _composeN(6);
        uint256 listed = _composedAt(sids[0]);
        for (uint256 i; i < 4; ++i) {
            _buyAtStart(sids[i]);
        }
        assertEq(ctl.anchorBps(), 24_413);
        _age(sids[4], 400 * H);
        uint256 anchor = ctl.anchorBps();
        uint256 start = ctl.startBps();
        uint256 stored = ctl.storedAnchorBps();
        uint256 at = ctl.anchorTime();
        uint256 ask = ctl.priceOf(sids[5]);
        assertEq(stored, 24_413);
        assertEq(at, listed);
        assertEq(anchor, 12_766, "24_413 decayed over 400 hours of a 7 day half life");
        assertEq(ask, _cost(sids[5]) * 7_500 / 10_000, "the held statement is at the floor");
        vm.recordLogs();
        _pay(buyer, sids[4], ctl.priceOf(sids[4]));
        assertEq(ctl.anchorBps(), anchor, "anchor after the first floor sale");
        assertEq(ctl.startBps(), start);
        assertEq(ctl.priceOf(sids[5]), ask);
        _pay(buyer, sids[5], ctl.priceOf(sids[5]));
        assertEq(_moved(vm.getRecordedLogs()), 0, "no AnchorMoved");
        assertEq(ctl.anchorBps(), anchor, "anchor after the second floor sale");
        assertEq(ctl.storedAnchorBps(), stored);
        assertEq(ctl.anchorTime(), at);
        assertEq(ctl.startBps(), start, "the fresh ask is unchanged");
    }

    // promise: SPEC 1 anchor decays with its half life
    /// the part of the anchor above 10_000 halves every half life, continuously, and stops at 10_000
    function test_anchor_decaysWithTime() public {
        _anchor(30_000);
        uint256 t0 = block.timestamp;
        assertEq(ctl.anchorTime(), t0);
        assertEq(ctl.anchorBps(), 30_000);
        vm.warp(t0 + 7 days);
        assertApproxEqAbs(ctl.anchorBps(), 20_000, 1, "one half life");
        vm.warp(t0 + 14 days);
        assertApproxEqAbs(ctl.anchorBps(), 15_000, 1, "two half lives");
        vm.warp(t0 + 3.5 days);
        assertApproxEqAbs(ctl.anchorBps(), 24_142, 1, "half a half life");
        vm.warp(t0 + 365 days);
        assertEq(ctl.anchorBps(), 10_000, "the lower bound holds");
        vm.warp(t0 + 7 days * 300);
        assertEq(ctl.anchorBps(), 10_000, "after 256 half lives");
        assertEq(ctl.storedAnchorBps(), 30_000, "reads do not store");
        assertEq(ctl.anchorTime(), t0);
    }

    // promise: SPEC 1 anchor moves half way toward a sale above it
    /// a sale at 15_000 moves the anchor to the mean 12_500, and the next start is 18_750
    function test_anchor_aSaleAtTheStartMovesTheAnchorHalfWay() public {
        uint256 sid = _composeN(1)[0];
        _age(sid, 0);
        uint256 price = ctl.priceOf(sid);
        assertEq(price, _cost(sid) * 15_000 / 10_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorMoved(sid, 15_000, 12_500);
        _pay(buyer, sid, price);
        assertEq(ctl.anchorBps(), 12_500);
        assertEq(ctl.startBps(), 18_750);
    }

    // promise: disabling anchor movement leaves both its stored value and decay checkpoint unchanged
    function test_anchor_zeroMoveDoesNotRestartDecay() public {
        uint256 sid = _composeOnce().sid;
        Sale memory s = _sale();
        s.anchorMoveBps = 0;
        vm.prank(owner);
        ctl.setSale(s);
        _anchor(12_000);
        uint256 checkpoint = ctl.anchorTime();
        vm.warp(block.timestamp + 1 hours);
        uint256 current = ctl.anchorBps();
        uint256 price = ctl.priceOf(sid);
        assertGt(price * 10_000 / ctl.referenceOf(sid), current, "qualifying upward sale");
        vm.recordLogs();
        _pay(buyer, sid, price);
        assertEq(_moved(vm.getRecordedLogs()), 0);
        assertEq(ctl.anchorBps(), current);
        assertEq(ctl.storedAnchorBps(), 12_000);
        assertEq(ctl.anchorTime(), checkpoint);
    }

    // promise: anchor movement takes the configured share of an odd upward gap, rounding the movement down
    function test_anchor_oddGapRoundsMovementDownAndFullMoveReachesSale() public {
        uint256 sid = _composeOnce().sid;
        Sale memory s = _sale();
        s.markupBps = 15_001;
        s.anchorMoveBps = 5_000;
        vm.prank(owner);
        ctl.setSale(s);
        _age(sid, 0);
        uint256 price = ctl.priceOf(sid);
        uint256 ref = ctl.referenceOf(sid);
        uint256 saleBps = (price * 10_000 + ref - 1) / ref;
        assertEq(saleBps, 15_001, "sale bps round the ask back up");
        _pay(buyer, sid, price);
        assertEq(ctl.anchorBps(), 12_500, "half of the 5,001 gap rounds down");
        sid = _another();
        s.anchorMoveBps = 10_000;
        vm.prank(owner);
        ctl.setSale(s);
        _age(sid, 0);
        price = ctl.priceOf(sid);
        ref = ctl.referenceOf(sid);
        saleBps = (price * 10_000 + ref - 1) / ref;
        _pay(buyer, sid, price);
        assertEq(ctl.anchorBps(), saleBps, "full movement reaches the observed sale bps");
    }

    // promise: SPEC 1 the start cap bounds the anchor
    /// a cap lowered below the anchor resets the anchor to the cap
    function test_anchor_neverPassesTheCap() public {
        _saleSettings(40_000, 40_000, 12, 10_000);
        vm.prank(owner);
        ctl.setAnchorBps(40_000);
        assertEq(ctl.anchorBps(), 40_000, "the anchor is at the cap");
        Sale memory s = _sale();
        s.markupBps = 12_000;
        s.startCapBps = 12_000;
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorBpsSet(12_000);
        vm.prank(owner);
        ctl.setSale(s);
        assertEq(ctl.anchorBps(), 12_000, "the start cap bounds the anchor");
    }

    // promise: SPEC 1 the sale is recorded at the asking price
    /// the sale is recorded at the asking price, not at `msg.value`: the excess is refunded and does not move the anchor
    function test_anchor_buyRecordsTheAskNotMsgValue() public {
        uint256 sid = _composeN(1)[0];
        _age(sid, 0);
        uint256 price = ctl.priceOf(sid);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorMoved(sid, 15_000, 12_500);
        _payExtra(buyer, sid, price, 7 ether);
        assertEq(buyer.balance, 7 ether, "the excess came back");
        assertEq(address(ctl).balance, 0, "the controller holds no eth");
        assertEq(ctl.anchorBps(), 12_500, "recorded at the asking price");
    }

    // promise: SPEC 1 the anchor decays with no buyer over 8 days at the launch anchorMinCost
    /// SaleAnchorTest clears anchorMinCost to 0; this case restores the launch 0.1 eth. an owner raises the anchor,
    /// then 8 days pass with no buyer (past one 7 day half life). a statement composed before and one after open at the
    /// markup of the anchor at their compose time, so the later opening ask multiple is lower by the decay
    function test_anchorDecaysOverEightDaysWithNoBuyerAtLaunchMinCost() public {
        _setAnchorMinCost(0.1 ether);
        _anchor(30_000);
        uint256 a = _composeOnce().sid;
        uint256 anchorA = ctl.anchorBps();
        uint256 startA = ctl.startBps();
        uint256 askA = ctl.priceOf(a);
        assertEq(anchorA, 30_000, "the anchor starts elevated");
        assertEq(startA, 15_000 * 30_000 / 10_000, "the opening markup at the elevated anchor");

        vm.warp(block.timestamp + 8 days);
        uint256 b = _another();
        uint256 anchorB = ctl.anchorBps();
        uint256 askB = ctl.priceOf(b);

        uint256 expectAnchor = 10_000 + Halving.halve(20_000, 8 days, 7 days);
        assertApproxEqAbs(anchorB, expectAnchor, 2, "the anchor halved past one half life with no buyer");
        assertLt(anchorB, anchorA, "the anchor decayed");
        assertEq(ctl.startBps(), 15_000 * anchorB / 10_000, "the opening markup fell with the decayed anchor");
        assertLt(
            askB * 10_000 / _cost(b), askA * 10_000 / _cost(a), "the later opening ask multiple is lower by the decay"
        );
        assertEq(ctl.storedAnchorBps(), 30_000, "no buyer checkpointed the anchor, the stored value is unchanged");
    }

    // promise: SPEC 1 a refused buy leaves the anchor
    /// a refused or underpaid buy leaves the anchor where it was
    function test_anchor_aRevertedBuyDoesNotMoveIt() public {
        uint256 sid = _composeN(1)[0];
        _age(sid, 0);
        uint256 price = ctl.priceOf(sid);
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: price - 1}(sid);
        assertEq(ctl.anchorBps(), 10_000);
        // a statement that is not for sale
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.buy{value: price}(sid + 1000);
        assertEq(ctl.anchorBps(), 10_000);
    }
}

/// the linear fall of the asking price: exact points, live settings on held statements, the
/// order of the setters, and the shape of the price in the age
contract SaleDecayTest is SaleShapeBase {
    // promise: SPEC 1 every economic number is an owner setting, effective at once
    /// each of the four settings moves a held statement to the value the new rule gives for its age
    function test_decay_settingsMoveAnOpenListingAtOnce() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        // this suite holds saleFloorBps at 7_500, so the launch line runs 150 percent to 75 percent over 12 hours
        _age(sid, 6 * H);
        assertEq(ctl.priceOf(sid), cost * 11_250 / 10_000, "launch rule: halfway through the 12 hour window at hour 6");
        vm.startPrank(owner);
        Sale memory s = _sale();
        s.decayHours = 24;
        ctl.setSale(s);
        vm.stopPrank();
        assertEq(ctl.priceOf(sid), cost * 13_125 / 10_000, "decay 24 hours: hour 6 is a quarter of the way down");
        _markupThenFloor(20_000, 20_000);
        assertEq(ctl.priceOf(sid), cost * 20_000 / 10_000, "a floor at the start lifts the ask");
        _markupThenFloor(15_000, 7_500);
        s = _sale();
        s.decayHours = 12;
        vm.prank(owner);
        ctl.setSale(s);
        assertEq(ctl.priceOf(sid), cost * 11_250 / 10_000, "back to the launch rule");
    }

    // promise: SPEC 2 sale settings reachable inside their bounds
    /// one `setSale` call reaches any valid combination: the cap and the markup rise together, then fall together to
    /// their floors, and `decayHours` moves across its whole range
    function test_decay_oneCallReachesAnyValidCombination() public {
        Sale memory s = _sale();
        vm.startPrank(owner);
        s.markupBps = type(uint16).max;
        s.startCapBps = type(uint32).max;
        s.decayHours = type(uint16).max;
        ctl.setSale(s);
        assertEq(ctl.startCapBps(), type(uint32).max);
        assertEq(ctl.decayHours(), type(uint16).max);
        s.markupBps = 10_000;
        s.startCapBps = 10_000;
        s.decayHours = 1;
        ctl.setSale(s);
        vm.stopPrank();
        assertEq(ctl.startCapBps(), 10_000);
        assertEq(ctl.decayHours(), 1);
    }

    /// answers the controller's reads of the Core for the price fuzz: the cost and the compose time of any statement
    StatementInfoStub internal stub;
    /// the `saleFloorBps` the stub answers
    uint16 internal fuzzFloor;

    /// a controller with random valid settings and a random anchor, created after `warp` seconds so the anchor has not decayed
    function _decayControllerFuzz(uint256[8] memory x, uint256 warp)
        internal
        returns (IControllerV1 c, Sale memory k, uint256 anchor)
    {
        vm.warp(block.timestamp + warp);
        stub = new StatementInfoStub(owner);
        fuzzFloor = uint16(bound(x[2], 0, type(uint16).max));
        stub.setSaleFloorBps(fuzzFloor);
        k.markupBps = uint16(bound(x[0], fuzzFloor > 10_000 ? fuzzFloor : 10_000, type(uint16).max));
        k.startCapBps = uint32(bound(x[1], k.markupBps, type(uint32).max));
        k.decayHours = uint16(bound(x[3], 1, type(uint16).max));
        k.anchorHalfLife = 7 days;
        c = Prod.newController(address(stub), k);
        anchor = bound(x[6], 10_000, k.startCapBps);
        vm.prank(owner);
        c.setAnchorBps(uint32(anchor));
    }

    function _at(IControllerV1 c, uint256 cost, uint256 age) internal returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        stub.set(cost, uint64(block.timestamp - age));
        return c.priceOf(0);
    }

    function _closedForm(IControllerV1 c, Sale memory k, uint256 cost, uint256 age) internal view returns (uint256) {
        return _curve(cost, c.startBps(), fuzzFloor, k.decayHours, age);
    }

    // promise: SPEC 1 the asking price never rises with age
    /// for any valid settings and anchor the price never rises with the age, starts at the start price, stays at or
    /// above the floor and equals the closed form
    function testFuzz_decay_priceNeverRisesWithAge(uint256[8] memory x, uint128 cost_, uint32 a1, uint32 gap) public {
        uint256 age2 = uint256(a1) + gap;
        (IControllerV1 c, Sale memory k,) = _decayControllerFuzz(x, age2 + 1);
        uint256 cost = bound(cost_, 1, type(uint128).max);
        uint256 p1 = _at(c, cost, a1);
        uint256 p2 = _at(c, cost, age2);
        assertLe(p2, p1, "non-increasing in the age");
        assertLe(p1, cost * c.startBps() / 10_000, "at most the start");
        assertGe(p2, cost * fuzzFloor / 10_000, "at least the floor");
        assertEq(_at(c, cost, 0), cost * c.startBps() / 10_000, "age zero is the start");
        assertEq(p1, _closedForm(c, k, cost, a1));
        assertEq(p2, _closedForm(c, k, cost, age2));
    }
}

/// a recipient that refuses eth
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

/// the artist and operator cuts of nft sales: a fixed share of each statement and credit sale payment,
/// `saleToArtistBps` and `saleToOperatorBps`, is taken off the top and pushed to the artist and the payee, the rest is
/// split by the existing rules. the pushes are forced, so a recipient that cannot receive never blocks the sale
contract SaleCutsTest is SaleBase {
    address internal buyer = address(0xB0B);

    // promise: SPEC 1 the statement sale splits sum to the payment
    function test_cuts_statementSaleSplitsSumToThePayment() public {
        uint256 sid = _composeOnce().sid;
        uint256 price = ctl.priceOf(sid);
        (uint256 toArtist, uint256 toOperator, uint256 rest) = _saleCuts(price);
        uint256 artist0 = core.artist().balance;
        uint256 payee0 = core.payee().balance;
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        _pay(buyer, sid, price);
        assertEq(core.artist().balance - artist0, toArtist, "the artist cut was pushed");
        assertEq(core.payee().balance - payee0, toOperator, "the operator cut was pushed to the payee");
        uint256 dPot = core.ethPot() - pot0;
        uint256 dBb = core.ethToBuyback() - bb0;
        assertEq(dPot + dBb, rest, "the pot and the buyback together take the rest");
        assertEq(toArtist + toOperator + dPot + dBb, price, "the cuts and the rest sum to the payment");
        _solvent();
    }

    // promise: SPEC 1 the credit sale splits sum to the payment
    function test_cuts_creditSaleSplitsSumToThePayment() public {
        uint256[] memory ids = _fillEthPile(1);
        _setCreditSaleOn(true);
        uint256 id = ids[0];
        uint256 price = ctl.creditPrice(id);
        (uint256 toArtist, uint256 toOperator, uint256 rest) = _saleCuts(price);
        uint256 artist0 = core.artist().balance;
        uint256 payee0 = core.payee().balance;
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        vm.deal(buyer, price);
        vm.prank(buyer);
        ctl.buyCredit{value: price}(id);
        assertEq(core.artist().balance - artist0, toArtist, "the artist cut was pushed");
        assertEq(core.payee().balance - payee0, toOperator, "the operator cut was pushed to the payee");
        assertEq((core.ethPot() - pot0) + (core.ethToBuyback() - bb0), rest, "the rest is booked");
        assertEq(toArtist + toOperator + rest, price, "the splits sum to the payment");
        _solvent();
    }

    // promise: SPEC 1 the forced push reaches an artist that reverts and the sale settles
    function test_cuts_pushReachesAnArtistThatReverts() public {
        RejectsEth bad = new RejectsEth();
        vm.prank(owner);
        core.setArtist(address(bad));
        uint256 sid = _composeOnce().sid;
        uint256 price = ctl.priceOf(sid);
        (uint256 toArtist,,) = _saleCuts(price);
        uint256 before = address(bad).balance;
        _pay(buyer, sid, price);
        assertEq(STATEMENTS.ownerOf(sid), buyer, "the sale went through");
        assertEq(address(bad).balance - before, toArtist, "the forced push reached the reverting artist");
    }

    // promise: SPEC 1 a zero cut skips its push
    function test_cuts_zeroBpsSkipsThePush() public {
        Settings memory s = core.settings();
        s.saleToArtistBps = 0;
        _setSettings(s);
        uint256 sid = _composeOnce().sid;
        uint256 price = ctl.priceOf(sid);
        (uint256 toArtist, uint256 toOperator,) = _saleCuts(price);
        assertEq(toArtist, 0, "the artist cut is zero");
        uint256 artist0 = core.artist().balance;
        uint256 payee0 = core.payee().balance;
        _pay(buyer, sid, price);
        assertEq(core.artist().balance, artist0, "the artist receives nothing at a zero cut");
        assertEq(core.payee().balance - payee0, toOperator, "the operator cut still pushes");
    }

    // promise: SPEC 1 setArtist refuses the zero address while the cut is on, accepts it at a zero cut
    function test_cuts_setArtistZeroRefusedWhileTheCutIsOn() public {
        assertGt(core.settings().saleToArtistBps, 0, "the cut is on at launch");
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setArtist(address(0));
        Settings memory s = core.settings();
        s.saleToArtistBps = 0;
        _setSettings(s);
        // the royalty on purchases keeps the artist required as well (decision 163)
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setArtist(address(0));
        s.buyToArtistBps = 0;
        _setSettings(s);
        vm.prank(owner);
        core.setArtist(address(0));
        assertEq(core.artist(), address(0), "the artist is cleared when both cuts are off");
    }

    // promise: SPEC 1 setSettings refuses a nonzero artist cut while the artist is the zero address, so the pair is
    // checked on both setters and the cut can never be pushed to address(0)
    function test_cuts_setSettingsRefusesCutWhileArtistZero() public {
        // clear both cuts, then the artist, so the artist is the zero address with no cut
        Settings memory s = core.settings();
        s.saleToArtistBps = 0;
        s.buyToArtistBps = 0;
        _setSettings(s);
        vm.prank(owner);
        core.setArtist(address(0));
        assertEq(core.artist(), address(0), "the artist is cleared");
        // raising the cut while the artist is zero reverts
        s.saleToArtistBps = 250;
        vm.prank(owner);
        vm.expectRevert(ICore.ZeroAddress.selector);
        core.setSettings(s);
    }

    // promise: SPEC 1 setArtist refuses a forbidden target
    function test_cuts_setArtistRefusesAForbiddenTarget() public {
        vm.prank(owner);
        vm.expectRevert(ICore.ForbiddenTarget.selector);
        core.setArtist(address(core));
    }

    // promise: INTEGRATION OnlyOwner on setArtist
    function test_cuts_setArtistOnlyTheOwner() public {
        vm.prank(address(0x5757));
        vm.expectRevert(ICore.OnlyOwner.selector);
        core.setArtist(address(0xA11CE));
    }
}

/// the first statement sale at the launch settings, with no reference pin: the reference is max(cost, valueOf(rating))
/// read live from a moving rate, and the launch curve runs 150 percent of it to 100 percent over 12 hours
contract SaleLaunchColdTest is SaleBase {
    // promise: SPEC 1 the launch curve prices a cold composed statement at startBps of max(cost, valueOf), no pin
    function test_firstStatementSaleAtLaunchWithoutTheReferencePin() public {
        assertEq(ctl.anchorMinCost(), 0.1 ether, "launch anchorMinCost");
        assertEq(core.settings().dropFloorBps, 1, "launch drop floor");
        assertEq(core.settings().saleFloorBps, 10_000, "launch sale floor");
        assertEq(ctl.startBps(), 15_000, "the opening markup at launch");
        uint256 sid = _composeOnce().sid;

        // the reference is read live at each age (no _pinReferenceToCost), the ask is the launch 4 hour curve of it
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid) * 15_000 / 10_000, "age 0: 150 percent of the live reference");
        _age(sid, 2 * H);
        assertEq(
            ctl.priceOf(sid), ctl.referenceOf(sid) * 12_500 / 10_000, "age 2 h: 125 percent, the midpoint of the 4 hour line"
        );
        _age(sid, 4 * H);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid), "age 4 h: the sale floor, 100 percent of the live reference");
        _age(sid, 12 * H);
        assertEq(ctl.priceOf(sid), ctl.referenceOf(sid), "past the window: still at the floor");
    }
}
