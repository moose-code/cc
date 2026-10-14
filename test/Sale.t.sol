// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Sale, CreditSale, Settings, Mainnet} from "../src/interfaces/Interfaces.sol";
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

    function _composedAt(uint256 sid) internal view returns (uint64 at) {
        (,, at) = core.statementInfo(sid);
    }

    /// moves the clock to `secs` after the statement was composed
    function _age(uint256 sid, uint256 secs) internal {
        vm.warp(_composedAt(sid) + secs);
    }

    /// sets the six sale numbers in one call. the floor is the core `saleFloorBps`
    function _saleSettings(
        uint16 markup,
        uint32 cap,
        uint16 fast,
        uint32 knee,
        uint16 slow,
        uint16 floor_
    ) internal {
        _floorBps(floor_);
        Sale memory s = _sale();
        (s.markupBps, s.startCapBps, s.fastDecayBpsPerHour, s.kneeBps, s.slowDecayBpsPerHour) =
            (markup, cap, fast, knee, slow);
        vm.prank(owner);
        ctl.setSale(s);
    }

    function _anchor(uint32 bps) internal {
        vm.prank(owner);
        ctl.setAnchorBps(bps);
    }

    /// the asking price in wei at `age` seconds: `start` falls `fast` bps an hour to `knee`, then `slow` bps an hour to
    /// `floor_`. all bps of `cost`. the price is counted in 1/3600 bps, the second of the rate
    function _curve(uint256 cost, uint256 start, uint256 knee, uint256 fast, uint256 slow, uint256 floor_, uint256 age)
        internal
        pure
        returns (uint256)
    {
        uint256 units;
        uint256 fastSpan = start > knee ? (start - knee) * 3600 : 0;
        if (age * fast <= fastSpan) {
            units = start * 3600 - age * fast;
        } else {
            uint256 base = (start < knee ? start : knee) * 3600;
            uint256 drop = (slow * (age * fast - fastSpan) + fast - 1) / fast;
            units = base > drop ? base - drop : 0;
        }
        if (units < floor_ * 3600) units = floor_ * 3600;
        return cost * units / (3600 * 10_000);
    }

    /// the launch curve: 150 percent falling 1 percent an hour to 100, then 0.25 percent an hour to 75 at hour 150
    function _launch(uint256 cost, uint256 age) internal pure returns (uint256) {
        return _curve(cost, 15_000, 10_000, 100, 25, 7_500, age);
    }

    function _floorBps(uint16 bps) internal {
        Settings memory s = core.settings();
        s.saleFloorBps = bps;
        _setSettings(s);
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

    /// the royalty on an engine price at the controller's current `royaltyBps`
    function _royaltyOn(uint256 price) internal view returns (uint256) {
        return price * ctl.royaltyBps() / 10_000;
    }

    /// `who` pays the engine price `price` plus the royalty on it
    function _pay(address who, uint256 sid, uint256 price) internal {
        _payExtra(who, sid, price, 0);
    }

    /// `who` pays the engine price, the royalty and `extra` on top
    function _payExtra(address who, uint256 sid, uint256 price, uint256 extra) internal {
        uint256 value = price + _royaltyOn(price) + extra;
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
    /// guarantee in bps of cost. the reference is `max(cost, valueOf(rating))`, so the largest `refScore` and a
    /// `rateCap` at the opening rate hold the floor rate at or below the fill rate and keep the rate term far below
    /// cost, where the reference equals cost
    function _pinReferenceToCost() internal {
        _setRefScore(8_000_000);
        Settings memory s = core.settings();
        s.rateCap = uint64(OPEN_RATE);
        _setSettings(s);
    }
}

/// the two stage curve tests. the launch sale holds floor and knee at 100 percent of cost (decision 85), so the
/// price falls from its start to cost and stays there. these tests exercise the shape of a two stage curve, so setUp
/// sets `saleFloorBps` to 7_500 through the owner setter. the launch curve itself is
/// `SaleLaunchCurveTest`
abstract contract SaleShapeBase is SaleBase {
    function setUp() public virtual override {
        super.setUp();
        _pinReferenceToCost();
        _floorBps(7_500);
    }
}

/// the curve at the launch values: floor and knee at 100 percent of cost
contract SaleLaunchCurveTest is SaleBase {
    function setUp() public override {
        super.setUp();
        _pinReferenceToCost();
    }

    // promise: SPEC 1 launch curve falls from the start price to the statement reference and rests there (decision 85)
    function test_launchCurve_startsAtStartFallsToCostAndStaysAtCost() public {
        assertEq(ctl.kneeBps(), 10_000, "knee at launch");
        assertEq(core.settings().saleFloorBps, 10_000, "floor at launch");
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256[11] memory t =
            [uint256(0), 1, 25 * H, 49 * H, 50 * H - 1, 50 * H, 50 * H + 1, 100 * H, 150 * H, 1000 * H, 100_000 * H];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            uint256 ask = ctl.priceOf(sid);
            assertEq(ask, _curve(cost, 15_000, 10_000, 100, 25, 10_000, t[i]), "closed form at launch values");
            assertGe(ask, cost, "never below cost");
            assertLe(ask, cost * 15_000 / 10_000, "never above the start");
        }
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), cost * 15_000 / 10_000, "starts at 150 percent");
        _age(sid, 50 * H);
        assertEq(ctl.priceOf(sid), cost, "reaches cost at hour 50");
        _age(sid, 50 * H - 1);
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
        uint256[5] memory t = [uint256(0), 1, 52 * H, 150 * H, 5000 * H];
        for (uint256 i; i < hard.length; ++i) {
            _floorBps(hard[i]);
            for (uint256 j; j < t.length; ++j) {
                _age(sid, t[j]);
                uint256 ask = _curve(cost, 15_000, 10_000, 100, 25, hard[i], t[j]);
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
    // promise: SPEC 1 a raise of saleFloorBps reaches every held statement at once
    /// the floor is read live: a raised floor lifts the ask of a held statement at once, a lowered floor gives way
    /// to the curve again, and the buy pays the lifted price
    function test_floor_followsTheSettingAtOnce() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(ctl.priceOf(sid), cost * 15_000 / 10_000);
        _floorBps(20_000);
        assertEq(ctl.priceOf(sid), cost * 20_000 / 10_000, "a raised floor reaches the held statement");
        _floorBps(1_000);
        assertEq(ctl.priceOf(sid), cost * 15_000 / 10_000, "a lowered floor gives way to the curve");
        _floorBps(20_000);
        address buyer = address(0xB0B);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: cost * 15_000 / 10_000}(sid);
        assertEq(_buy(buyer, sid), cost * 20_000 / 10_000);
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
            (uint256 sid, uint256 price) = _buyAt(90 * H);
            assertEq(price, _cost(sid) * 9_000 / 10_000, "90 hours down the curve: 90 percent");
            (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
            uint256 n = core.heldStatements().length;
            vm.expectEmit(address(core));
            emit ICore.StatementSoldTo(sid, buyer, price, price * shares[i] / 10_000);
            vm.expectEmit(address(ctl));
            emit IControllerV1.Bought(sid, buyer, price);
            _pay(buyer, sid, price);
            assertEq(buyer.balance, 0, "exact payment, nothing back");
            assertEq(STATEMENTS.ownerOf(sid), buyer);
            assertEq(address(core).balance - bal0, price);
            assertEq(core.ethToBuyback() - bb0, price * shares[i] / 10_000);
            assertEq(core.ethPot() - pot0, price - price * shares[i] / 10_000);
            assertEq(address(ctl).balance, ctl.royaltyOwed(), "the controller holds the royalty owed");
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
        assertEq(address(ctl).balance, ctl.royaltyOwed());
    }

    // promise: INTEGRATION Underpaid
    function test_buy_underpayRevertsAndChangesNothing() public {
        (uint256 sid, uint256 price) = _buyAt(0);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        uint256 gross = ctl.grossPriceOf(sid);
        vm.deal(buyer, gross);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: gross - 1}(sid);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: price}(sid);
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
        vm.expectEmit(address(core));
        emit ICore.StatementSoldTo(sid, buyer, floor, floor * core.settings().saleToBuybackBps / 10_000);
        sc.sell{value: floor}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertEq(address(core).balance - bal0, floor);
        assertEq(core.ethToBuyback() - bb0, floor * core.settings().saleToBuybackBps / 10_000);
        assertEq(core.ethPot() - pot0, floor - floor * core.settings().saleToBuybackBps / 10_000);
        assertEq(address(sc).balance, scBal, "the controller keeps nothing");
        _solvent();
    }

    // promise: SPEC 4 sellTo books the whole payment (inv 5, inv 18)
    /// the whole payment is booked, an overpayment included: the core has no refund logic
    function test_sellTo_booksEverythingItIsPaid() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 pay = _floorOf(sid) * 5;
        _buybackBps(2_500);
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        sc.sell{value: pay}(sid, buyer);
        assertEq(core.ethToBuyback() - bb0, pay * 2_500 / 10_000);
        assertEq(core.ethPot() - pot0, pay - pay * 2_500 / 10_000);
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
        uint256 gross = ctl.grossPriceOf(a);
        (uint256 pot0, uint256 bb0,) = _recordedBook();
        vm.deal(address(this), gross + 2 ether);
        uint256 pre = address(rb).balance;
        rb.buy{value: gross + 2 ether}(a);
        assertEq(STATEMENTS.ownerOf(a), address(rb), "the buy went through");
        assertEq(address(rb).balance - pre, 2 ether, "and the refund landed");
        assertEq(rb.reentries(), 1);
        assertTrue(rb.buyBlocked(), "a second buy from the refund is refused");
        assertEq(rb.buySel(), IControllerV1.Reentrant.selector);
        assertTrue(rb.sellBlocked(), "sellTo is the controller's alone");
        assertTrue(rb.redeemBlocked());
        assertEq(STATEMENTS.ownerOf(b), address(core), "the other statement is untouched");
        assertEq(core.ethPot() - pot0 + core.ethToBuyback() - bb0, price, "booked exactly once");
        _solvent();
    }

    // promise: INTEGRATION buy refunds the excess last
    function test_reenter_aBuyerThatRefusesTheRefundCanOnlyPayExactly() public {
        uint256 sid = _composeOnce().sid;
        RefundRefuser rr = new RefundRefuser(ctl);
        uint256 gross = ctl.grossPriceOf(sid);
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
            fastDecayBpsPerHour: lc.sale.fastDecayBpsPerHour,
            kneeBps: lc.sale.kneeBps,
            slowDecayBpsPerHour: lc.sale.slowDecayBpsPerHour,
            anchorHalfLife: lc.sale.anchorHalfLife,
            anchorMinCost: lc.sale.anchorMinCost
        });
    }

    function _bad(bytes32 field) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IControllerV1.BadSetting.selector, field);
    }

    // promise: SPEC 2 sale settings at launch
    function test_settings_launchValues() public view {
        assertEq(lc.sale.markupBps, 15_000);
        assertEq(lc.sale.startCapBps, 100_000);
        assertEq(lc.sale.fastDecayBpsPerHour, 100);
        assertEq(lc.sale.kneeBps, 10_000);
        assertEq(lc.sale.slowDecayBpsPerHour, 25);
        assertEq(lc.sale.anchorHalfLife, 7 days);
        assertEq(lc.sale.anchorMinCost, 0.1 ether);
        assertEq(abi.encode(Mainnet.defaultSale()), abi.encode(lc.sale), "the launch sale");
        assertEq(ctl.markupBps(), 15_000);
        assertEq(ctl.startCapBps(), 100_000);
        assertEq(ctl.fastDecayBpsPerHour(), 100);
        assertEq(ctl.kneeBps(), 10_000);
        assertEq(ctl.slowDecayBpsPerHour(), 25);
        assertEq(core.settings().saleFloorBps, 10_000);
        assertEq(ctl.royaltyBps(), 250);
        assertEq(ctl.royaltyRecipient(), creator);
        assertEq(ctl.royaltyOwed(), 0);
        assertEq(ctl.anchorHalfLife(), 7 days);
        assertEq(ctl.anchorMinCost(), 0.1 ether);
        assertEq(ctl.anchorBps(), 10_000, "the anchor starts at the cost");
        assertEq(ctl.storedAnchorBps(), 10_000);
        assertEq(ctl.anchorTime(), block.timestamp);
        assertEq(ctl.startBps(), 15_000);
    }

    /// every upper edge of the sale settings, and every lower edge
    function _hi() internal pure returns (Sale memory) {
        return Sale(40_000, 200_000, 10_000, 200_000, 10_000, 90 days, 10 ether);
    }

    function _lo() internal pure returns (Sale memory) {
        return Sale(10_000, 10_000, 1, 1_000, 1, 1 days, 0);
    }

    function _saleBad(Sale memory s, bytes32 field) internal {
        vm.expectRevert(_bad(field));
        ctl.setSale(s);
    }

    function _creditBad(CreditSale memory c, bytes32 field) internal {
        vm.expectRevert(_bad(field));
        ctl.setCredit(c);
    }

    // promise: INTEGRATION BadSetting on the controller setters
    function test_settings_boundsOfEverySetter() public {
        vm.startPrank(owner);
        // every upper edge is accepted in one call, then every lower edge
        ctl.setSale(_hi());
        ctl.setSale(_lo());
        // one field past its edge, the others valid
        Sale memory s = _hi();
        s.markupBps = 40_001;
        _saleBad(s, "markupBps");
        s = _hi();
        s.startCapBps = 39_999;
        _saleBad(s, "startCapBps");
        s.startCapBps = 200_001;
        _saleBad(s, "startCapBps");
        s = _hi();
        s.kneeBps = 200_001;
        _saleBad(s, "kneeBps");
        s = _hi();
        s.startCapBps = 100_000;
        _saleBad(s, "kneeBps");
        s = _lo();
        s.markupBps = 9_999;
        _saleBad(s, "markupBps");
        s = _lo();
        s.kneeBps = 999;
        _saleBad(s, "kneeBps");
        s = _hi();
        s.fastDecayBpsPerHour = 10_001;
        _saleBad(s, "fastDecayBpsPerHour");
        s = _lo();
        s.fastDecayBpsPerHour = 0;
        _saleBad(s, "fastDecayBpsPerHour");
        s = _hi();
        s.slowDecayBpsPerHour = 10_001;
        _saleBad(s, "slowDecayBpsPerHour");
        s = _lo();
        s.slowDecayBpsPerHour = 0;
        _saleBad(s, "slowDecayBpsPerHour");
        s = _lo();
        s.anchorHalfLife = 1 days - 1;
        _saleBad(s, "anchorHalfLife");
        s = _hi();
        s.anchorHalfLife = 90 days + 1;
        _saleBad(s, "anchorHalfLife");
        s = _hi();
        s.anchorMinCost = 10 ether + 1;
        _saleBad(s, "anchorMinCost");
        s.anchorMinCost = type(uint128).max;
        _saleBad(s, "anchorMinCost");
        // royalty: 0 to 1_000, recipient never zero
        CreditSale memory c = _creditSale();
        c.royaltyBps = 0;
        ctl.setCredit(c);
        c.royaltyBps = 1_000;
        ctl.setCredit(c);
        c.royaltyBps = 1_001;
        _creditBad(c, "royaltyBps");
        c.royaltyBps = 1_000;
        c.royaltyRecipient = address(0);
        _creditBad(c, "royaltyRecipient");
        // anchorBps 10_000 to the cap
        ctl.setSale(_hi());
        vm.expectRevert(_bad("anchorBps"));
        ctl.setAnchorBps(9_999);
        ctl.setAnchorBps(10_000);
        ctl.setAnchorBps(200_000);
        vm.expectRevert(_bad("anchorBps"));
        ctl.setAnchorBps(200_001);
        vm.stopPrank();
        assertEq(ctl.anchorMinCost(), 10 ether);
        assertEq(ctl.anchorHalfLife(), 90 days);
        assertEq(ctl.markupBps(), 40_000);
        assertEq(ctl.startCapBps(), 200_000);
        assertEq(ctl.fastDecayBpsPerHour(), 10_000);
        assertEq(ctl.slowDecayBpsPerHour(), 10_000);
        assertEq(ctl.kneeBps(), 200_000);
        assertEq(ctl.royaltyBps(), 1_000);
        assertEq(ctl.anchorBps(), 200_000);
        assertEq(ctl.startBps(), 200_000, "800_000 is held at the cap");
    }

    // promise: SPEC 1 every economic number is an owner setting, effective at once
    function test_settings_eventsAndValues() public {
        Sale memory s = Sale(12_000, 150_000, 200, 12_000, 50, 3 days, 0.25 ether);
        CreditSale memory c = _creditSale();
        c.royaltyBps = 300;
        c.royaltyRecipient = address(0xA27);
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
        assertEq(ctl.fastDecayBpsPerHour(), 200);
        assertEq(ctl.slowDecayBpsPerHour(), 50);
        assertEq(ctl.kneeBps(), 12_000);
        assertEq(ctl.royaltyBps(), 300);
        assertEq(ctl.royaltyRecipient(), address(0xA27));
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
        c.royaltyBps = 300;
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
        assertEq(ctl.markupBps(), 15_000);
        assertEq(ctl.anchorBps(), 10_000);
    }

    // promise: SPEC 2 controller constructor bounds
    function test_settings_constructorBounds() public {
        Sale memory s = _fresh();
        s.markupBps = 9_999;
        vm.expectRevert(_bad("markupBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.markupBps = 40_001;
        s.startCapBps = 200_000;
        vm.expectRevert(_bad("markupBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.startCapBps = s.markupBps - 1;
        vm.expectRevert(_bad("startCapBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.startCapBps = 200_001;
        vm.expectRevert(_bad("startCapBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.fastDecayBpsPerHour = 0;
        vm.expectRevert(_bad("fastDecayBpsPerHour"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.fastDecayBpsPerHour = 10_001;
        vm.expectRevert(_bad("fastDecayBpsPerHour"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.slowDecayBpsPerHour = 0;
        vm.expectRevert(_bad("slowDecayBpsPerHour"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.slowDecayBpsPerHour = 10_001;
        vm.expectRevert(_bad("slowDecayBpsPerHour"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.kneeBps = 999;
        vm.expectRevert(_bad("kneeBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.kneeBps = s.startCapBps + 1;
        vm.expectRevert(_bad("kneeBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.anchorHalfLife = 1 days - 1;
        vm.expectRevert(_bad("anchorHalfLife"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.anchorHalfLife = 90 days + 1;
        vm.expectRevert(_bad("anchorHalfLife"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.anchorMinCost = 10 ether + 1;
        vm.expectRevert(_bad("anchorMinCost"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.anchorMinCost = 10 ether;
        assertEq(Prod.newController(address(core), s).anchorMinCost(), 10 ether);
        s = _fresh();
        s.anchorMinCost = 0;
        assertEq(Prod.newController(address(core), s).anchorMinCost(), 0);
        s = _fresh();
        IControllerV1 c = Prod.newController(address(core), s);
        assertEq(c.anchorBps(), 10_000);
        assertEq(c.anchorHalfLife(), 7 days);
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
                vm.deal(attacker, attacker.balance + 1);
                vm.prank(attacker);
                core.fund{value: 1}();
                // refScore set to this credit's score, so a 1 wei pot reads a 1 wei bid for it (score / refScore is 1)
                _refScoreToCredit(ids[i]);
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

    // promise: SPEC 1 the start cap bounds the anchor
    /// a sale above the cap (a hard floor above it) cannot take the anchor past the cap
    function test_anchor_neverPassesTheCap() public {
        uint256 sid = _composeN(1)[0];
        _saleSettings(12_000, 12_000, 100, 10_000, 25, 7_500);
        _floorBps(30_000);
        _age(sid, 0);
        uint256 price = ctl.priceOf(sid);
        assertEq(price, _cost(sid) * 30_000 / 10_000, "the hard floor is above the cap");
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorMoved(sid, 30_000, 12_000);
        _pay(buyer, sid, price);
        assertEq(ctl.anchorBps(), 12_000);
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
        assertEq(address(ctl).balance, ctl.royaltyOwed());
        assertEq(ctl.anchorBps(), 12_500, "recorded at the asking price");
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

/// the two stage fall of the asking price: exact points, a start below the knee, live settings on held statements, the
/// order of the setters, and the shape of the price in the age
contract SaleDecayTest is SaleShapeBase {
    // promise: SPEC 1 every economic number is an owner setting, effective at once
    /// each of the four settings moves a held statement to the value the new rule gives for its age
    function test_decay_settingsMoveAnOpenListingAtOnce() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 60 * H);
        assertEq(ctl.priceOf(sid), cost * 9_750 / 10_000, "launch rule: 10 hours past the knee at 25 bps an hour");
        vm.startPrank(owner);
        Sale memory s = _sale();
        s.slowDecayBpsPerHour = 50;
        ctl.setSale(s);
        assertEq(ctl.priceOf(sid), cost * 9_500 / 10_000, "slow 50: 10 hours at 50");
        s.fastDecayBpsPerHour = 200;
        ctl.setSale(s);
        assertEq(ctl.priceOf(sid), cost * 8_250 / 10_000, "fast 200: the knee is at hour 25, 35 hours at 50");
        s.kneeBps = 12_000;
        ctl.setSale(s);
        assertEq(ctl.priceOf(sid), cost * 9_750 / 10_000, "knee 12_000: reached at hour 15, 45 hours at 50");
        vm.stopPrank();
        _floorBps(9_900);
        assertEq(ctl.priceOf(sid), cost * 9_900 / 10_000, "floor 9_900 lifts it");
        _floorBps(7_500);
        s.kneeBps = 10_000;
        s.fastDecayBpsPerHour = 100;
        s.slowDecayBpsPerHour = 25;
        vm.prank(owner);
        ctl.setSale(s);
        assertEq(ctl.priceOf(sid), cost * 9_750 / 10_000, "back to the launch rule");
    }

    // promise: SPEC 2 sale settings reachable inside their bounds
    /// one `setSale` call reaches any valid combination: the knee over the old cap, the cap under the old knee, and the
    /// knee at the cap
    function test_decay_oneCallReachesAnyValidCombination() public {
        Sale memory s = _sale();
        vm.startPrank(owner);
        // up: the knee and the cap rise together
        s.startCapBps = 150_000;
        s.kneeBps = 150_000;
        ctl.setSale(s);
        assertEq(ctl.kneeBps(), 150_000);
        // down: the cap and the knee fall together, the knee to its floor
        s.startCapBps = 15_000;
        s.kneeBps = 1_000;
        ctl.setSale(s);
        assertEq(ctl.kneeBps(), 1_000);
        assertEq(ctl.startCapBps(), 15_000);
        // the knee at the cap
        s.kneeBps = 15_000;
        ctl.setSale(s);
        vm.stopPrank();
        assertEq(ctl.kneeBps(), 15_000);
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
        fuzzFloor = uint16(bound(x[2], 1_000, 10_000));
        stub.setSaleFloorBps(fuzzFloor);
        k.markupBps = uint16(bound(x[0], 10_000, 40_000));
        k.startCapBps = uint32(bound(x[1], k.markupBps, 200_000));
        k.kneeBps = uint32(bound(x[3], 1_000, k.startCapBps));
        k.fastDecayBpsPerHour = uint16(bound(x[4], 1, 10_000));
        k.slowDecayBpsPerHour = uint16(bound(x[5], 1, 10_000));
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
        return _curve(
            cost, c.startBps(), k.kneeBps, k.fastDecayBpsPerHour, k.slowDecayBpsPerHour, fuzzFloor, age
        );
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

/// the royalty (decision 112): every sale of the controller adds `royaltyBps` of the engine price on top. the engine
/// receives the engine price, the controller holds the royalty until `claimRoyalty` pays the recipient
contract SaleRoyaltyTest is SaleBase {
    address internal buyer = address(0xB0B);

    // promise: SPEC 1 royalty on every engine sale (decision 112)
    /// the engine books the engine price, the controller holds the royalty, the refund is the rest
    function test_royalty_buySplitsTheGrossPrice() public {
        uint256 sid = _composeOnce().sid;
        uint256 p = ctl.priceOf(sid);
        uint256 r = p * 250 / 10_000;
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        _payExtra(buyer, sid, p, 2 ether);
        assertEq(buyer.balance, 2 ether, "the excess came back");
        assertEq(address(core).balance - bal0, p, "the engine took the engine price");
        assertEq((core.ethPot() - pot0) + (core.ethToBuyback() - bb0), p);
        assertEq(address(ctl).balance, r, "the controller holds the royalty");
        assertEq(ctl.royaltyOwed(), r);
        _solvent();
    }

    // promise: INTEGRATION Underpaid at the gross price
    function test_royalty_theEnginePriceAloneIsUnderpaid() public {
        uint256 sid = _composeOnce().sid;
        uint256 p = ctl.priceOf(sid);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: p}(sid);
        uint256 gross = ctl.grossPriceOf(sid);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: gross - 1}(sid);
        assertEq(ctl.royaltyOwed(), 0);
    }

    // promise: SPEC 1 royalty pull claim (decision 112)
    function test_royalty_claimPaysTheRecipientAndZeroes() public {
        uint256 sid = _composeOnce().sid;
        uint256 p = ctl.priceOf(sid);
        _pay(buyer, sid, p);
        uint256 owed = ctl.royaltyOwed();
        assertGt(owed, 0);
        address recipient = ctl.royaltyRecipient();
        uint256 before_ = recipient.balance;
        vm.expectEmit(address(ctl));
        emit IControllerV1.RoyaltyClaimed(recipient, owed);
        vm.prank(address(0xC1A1));
        ctl.claimRoyalty();
        assertEq(recipient.balance - before_, owed, "the recipient was paid");
        assertEq(ctl.royaltyOwed(), 0);
        assertEq(address(ctl).balance, 0);
        vm.expectRevert(IControllerV1.ZeroAmount.selector);
        ctl.claimRoyalty();
    }

    // promise: SPEC 1 a reverting royalty recipient blocks no sale
    /// a recipient that reverts blocks no sale. its claim reverts and keeps the royalty, and the owner names another
    function test_royalty_aRecipientThatRevertsBlocksNothing() public {
        RejectsEth bad = new RejectsEth();
        _setRoyaltyRecipient(address(bad));
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        _pay(buyer, a, ctl.priceOf(a));
        _pay(buyer, b, ctl.priceOf(b));
        assertEq(STATEMENTS.ownerOf(a), buyer);
        assertEq(STATEMENTS.ownerOf(b), buyer);
        uint256 owed = ctl.royaltyOwed();
        assertGt(owed, 0);
        vm.expectRevert();
        ctl.claimRoyalty();
        assertEq(ctl.royaltyOwed(), owed, "the royalty is kept");
        address good = address(0x600D);
        _setRoyaltyRecipient(good);
        ctl.claimRoyalty();
        assertEq(good.balance, owed, "the new recipient got what was owed");
        assertEq(ctl.royaltyOwed(), 0);
    }

    // promise: INTEGRATION ZeroAmount on claimRoyalty
    function test_royalty_zeroShareCollectsNothing() public {
        _setRoyaltyBps(0);
        uint256 sid = _composeOnce().sid;
        _pay(buyer, sid, ctl.priceOf(sid));
        assertEq(ctl.royaltyOwed(), 0);
        assertEq(address(ctl).balance, 0);
    }

}
