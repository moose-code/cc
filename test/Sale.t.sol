// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Prod} from "./utils/Prod.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {Lane, Sale, Settings, Mainnet} from "../src/interfaces/Interfaces.sol";
import {ScriptedController} from "./attackers/ScriptedController.sol";
import {SellingController, ReentrantBuyer, RefundRefuser} from "./attackers/SaleAttackers.sol";
import {StatementInfoStub} from "./standins/StatementInfoStub.sol";

/// the sale controller on the live fork: the asking price curve, the hard floor of the core, `buy` through `sellTo`,
/// the controller's own settings and its anchor. real Core, ControllerV1, Statements. the doubles are the scripted and
/// the attacker controllers only
abstract contract SaleBase is Fixture {
    uint256 internal constant H = 1 hours;

    function _cost(uint256 sid) internal view returns (uint256 cost) {
        (,, cost,) = core.statementInfo(sid);
    }

    function _composedAt(uint256 sid) internal view returns (uint64 at) {
        (,,, at) = core.statementInfo(sid);
    }

    /// the controller curve alone, below the hard floor too: `priceOf` read with the hard floor at its lowest bound,
    /// then the state is rolled back. `priceOf` is never below the hard floor
    function _raw(uint256 sid) internal returns (uint256 price) {
        uint256 snap = vm.snapshotState();
        _floorBps(1_000);
        price = ctl.priceOf(sid);
        vm.revertToState(snap);
    }

    /// moves the clock to `secs` after the statement was composed
    function _age(uint256 sid, uint256 secs) internal {
        vm.warp(_composedAt(sid) + secs);
    }

    /// sets the six sale numbers in an order that keeps every intermediate state inside the bounds: the cap rises
    /// before the knee, the floor falls before the knee, the cap falls after the knee
    function _saleSettings(
        uint16 markup,
        uint32 cap,
        uint16 fast,
        uint32 knee,
        uint16 slow,
        uint16 floor_
    ) internal {
        vm.startPrank(owner);
        if (cap > ctl.startCapBps()) ctl.setStartCapBps(cap);
        if (floor_ < ctl.floorBps()) ctl.setFloorBps(floor_);
        ctl.setKneeBps(knee);
        ctl.setFloorBps(floor_);
        ctl.setMarkupBps(markup);
        ctl.setStartCapBps(cap);
        ctl.setFastDecayBpsPerHour(fast);
        ctl.setSlowDecayBpsPerHour(slow);
        vm.stopPrank();
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

    function _pay(address who, uint256 sid, uint256 value) internal {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        ctl.buy{value: value}(sid);
    }

    function _pages(uint256[] memory ids) internal pure returns (uint256[80] memory p) {
        for (uint256 i; i < 80; ++i) {
            p[i] = ids[i];
        }
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
}

contract SaleCurveTest is SaleBase {
    /// the launch curve: 150 percent at listing, 100 at hour 50, 90 at hour 90, 75 at hour 150 and held after
    function test_curve_exactTimesAtLaunchSettings() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256[10] memory t =
            [uint256(0), 25 * H, 50 * H, 51 * H, 90 * H, 100 * H, 150 * H, 151 * H, 200 * H, 1000 * H];
        uint256[10] memory bps = [uint256(15_000), 12_500, 10_000, 9_975, 9_000, 8_750, 7_500, 7_500, 7_500, 7_500];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            assertEq(ctl.priceOf(sid), cost * bps[i] / 10_000, "ask");
            assertEq(_raw(sid), cost * bps[i] / 10_000, "controller curve");
        }
    }

    /// the price changes every second: one second in, one second before the end, and the closed form between
    function test_curve_isContinuousPerSecond() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint256[10] memory t =
            [uint256(1), 2, 60, 3 * H + 7, 49 * H + 1234, 50 * H - 1, 50 * H + 1, 90 * H + 17, 150 * H - 1, 150 * H + 1];
        uint256 prev = cost * 15_000 / 10_000;
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            uint256 ask = ctl.priceOf(sid);
            assertEq(ask, _launch(cost, t[i]), "closed form");
            assertLt(ask, prev, "it fell");
            prev = ask;
        }
        _age(sid, 150 * H);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000);
        _age(sid, 150 * H - 1);
        assertGt(ctl.priceOf(sid), cost * 7_500 / 10_000, "one second before the end it is still above the floor");
    }

    /// 150 at hour 0, 100 at hour 50, 90 at hour 90, 75 at hour 150 and held, written as percent
    function test_curve_ownerStatedPoints() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(ctl.startBps(), 15_000, "start is 150 percent of the anchor of 10_000");
        assertEq(ctl.priceOf(sid), cost * 150 / 100);
        _age(sid, 50 * H);
        assertEq(ctl.priceOf(sid), cost, "1 percent an hour reaches 100 percent at hour 50");
        _age(sid, 90 * H);
        assertEq(ctl.priceOf(sid), cost * 90 / 100, "1 percent every 4 hours after");
        _age(sid, 150 * H);
        assertEq(ctl.priceOf(sid), cost * 75 / 100);
        _age(sid, 200 * H);
        assertEq(ctl.priceOf(sid), cost * 75 / 100);
    }

    /// other settings, all at once: start 200 percent, 10 percent an hour to a knee of 150 percent, 5 percent an hour
    /// to a floor of 50 percent (below the core floor of 75)
    function test_curve_otherSettings() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(20_000, 100_000, 1_000, 15_000, 500, 5_000);
        uint256[5] memory t = [uint256(0), 5 * H, 7 * H, 25 * H, 40 * H];
        uint256[5] memory bps = [uint256(20_000), 15_000, 14_000, 5_000, 5_000];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            assertEq(_raw(sid), cost * bps[i] / 10_000, "ask");
            assertEq(ctl.priceOf(sid), cost * (bps[i] > 7_500 ? bps[i] : 7_500) / 10_000, "quote floored");
        }
    }

    /// the controller's floor below the core's hard floor: the line goes below, the quote does not
    function test_curve_controllerFloorBelowTheHardFloorIsLifted() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(15_000, 100_000, 100, 10_000, 25, 5_000);
        _age(sid, 300 * H);
        assertEq(_raw(sid), cost * 5_000 / 10_000, "the curve is at the controller floor");
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the quote is the hard floor");
    }

    /// the quote is never below the hard floor of the core, whatever the age and the hard floor setting
    function test_curve_priceOfStaysAtOrAboveTheHardFloor() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        uint16[3] memory hard = [uint16(1_000), 7_500, 12_000];
        uint256[5] memory t = [uint256(0), 1, 52 * H, 150 * H, 5000 * H];
        for (uint256 i; i < hard.length; ++i) {
            _floorBps(hard[i]);
            for (uint256 j; j < t.length; ++j) {
                _age(sid, t[j]);
                uint256 ask = _launch(cost, t[j]);
                uint256 floor = cost * hard[i] / 10_000;
                assertEq(ctl.priceOf(sid), ask > floor ? ask : floor, "the larger of the curve and the hard floor");
                assertGe(ctl.priceOf(sid), floor);
            }
        }
    }

    /// the fastest and the slowest rates, and a huge age
    function test_curve_rateBoundaries() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(15_000, 100_000, 10_000, 10_000, 10_000, 7_500);
        _age(sid, 30 minutes);
        assertEq(_raw(sid), cost * 10_000 / 10_000, "50 percent of cost fell in half an hour: at the knee");
        _age(sid, 45 minutes);
        assertEq(_raw(sid), cost * 7_500 / 10_000, "the slow stage reaches the floor in a quarter hour more");
        _age(sid, 10_000 days);
        assertEq(_raw(sid), cost * 7_500 / 10_000, "a huge age does not overflow");
        _saleSettings(15_000, 100_000, 1, 10_000, 1, 7_500);
        _age(sid, 2_500 * H);
        assertEq(_raw(sid), cost * 12_500 / 10_000, "one bps an hour, half way to the knee");
        _age(sid, 5_000 * H);
        assertEq(_raw(sid), cost);
        _age(sid, 6_000 * H);
        assertEq(_raw(sid), cost * 9_000 / 10_000);
        _age(sid, 7_500 * H - 1);
        assertGt(_raw(sid), cost * 7_500 / 10_000);
        _age(sid, 7_500 * H);
        assertEq(_raw(sid), cost * 7_500 / 10_000);
        _age(sid, 10_000 days);
        assertEq(_raw(sid), cost * 7_500 / 10_000, "a huge age does not overflow");
    }

    /// start equal to the floor is a flat price
    function test_curve_startAtTheFloorIsFlat() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _saleSettings(10_000, 100_000, 100, 10_000, 25, 10_000);
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), cost);
        _age(sid, 52 * H);
        assertEq(ctl.priceOf(sid), cost);
        _age(sid, 500 * H);
        assertEq(ctl.priceOf(sid), cost);
    }

    /// the cap holds the start price: a high anchor starts at the cap, a lower cap lowers the start at once
    function test_curve_startCapHoldsTheStart() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _anchor(80_000);
        assertEq(ctl.startBps(), 100_000, "80_000 times 1.5 is 120_000, held at the cap");
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), cost * 10, "an open listing asks the cap");
        _age(sid, 1_000 * H);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the curve ends at the floor");
        vm.prank(owner);
        ctl.setStartCapBps(20_000);
        _anchor(10_000);
        assertEq(ctl.startBps(), 15_000);
        _anchor(20_000);
        assertEq(ctl.startBps(), 20_000, "the cap is 20_000");
    }

    function test_curve_boundsBetweenTheFieldsAndTheConstructor() public {
        vm.startPrank(owner);
        // the markup cannot pass the cap, the cap cannot fall below the markup
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("startCapBps")));
        ctl.setStartCapBps(14_999);
        ctl.setStartCapBps(15_000);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("markupBps")));
        ctl.setMarkupBps(15_001);
        // the anchor is held between 10_000 and the cap
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("anchorBps")));
        ctl.setAnchorBps(15_001);
        vm.stopPrank();
        // a controller built with a cap below its markup is refused
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("startCapBps")));
        Prod.newController(
            address(core),
            Sale({
                markupBps: 15_000,
                startCapBps: 14_999,
                fastDecayBpsPerHour: 100,
                kneeBps: 10_000,
                slowDecayBpsPerHour: 25,
                floorBps: 7_500,
                anchorHalfLife: 7 days,
                anchorMinCost: 0.1 ether
            })
        );
    }

    function test_curve_priceOfRefusesWhatIsNotForSale() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(sid + 100);
        // an exit lane statement is never for sale
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.priceOf(xs);
    }
}

contract SaleFloorTest is SaleBase {
    function test_floor_beatsAHigherCoreFloor() public {
        _floorBps(20_000);
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        assertEq(_raw(sid), cost * 15_000 / 10_000, "the controller asks the start price");
        assertEq(ctl.priceOf(sid), cost * 20_000 / 10_000, "the quote is lifted to the hard floor");
    }

    /// the hard floor is read live: a raised floor lifts the ask of a held statement at once, a lowered floor gives way
    /// to the controller curve again, and the buy pays the lifted price
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

    /// a controller that cannot answer `nextPage` stops the compose and changes nothing, the statements already held
    /// stay for sale through the original controller only while it is the controller of the core
    function test_broken_nextPageStopsTheComposeAndKeepsEverything() public {
        _fillEthPile(80);
        ScriptedController sc = new ScriptedController();
        sc.setPage(Lane.Eth, true, _pages(core.pilePage(Lane.Eth, 0, 80)), 0);
        _setController(address(sc));
        sc.setRevertPage(true);
        vm.fee(composeBasefee);
        uint256 supply = STATEMENTS.supply();
        uint256 pot = core.ethPot();
        vm.prank(keeper);
        vm.expectRevert(ICore.NotReady.selector);
        core.compose();
        assertEq(STATEMENTS.supply(), supply, "nothing minted");
        assertEq(core.pileSize(Lane.Eth), 80, "the pile is whole");
        assertEq(core.ethPot(), pot, "no payment to the caller");
        assertEq(core.heldStatements().length, 0);
        // the same controller, repaired, composes
        sc.setRevertPage(false);
        vm.prank(keeper);
        core.compose();
        assertEq(core.heldStatements().length, 1);
    }
}

contract SaleBuyTest is SaleBase {
    address internal buyer = address(0xB0B);

    function _buyAt(uint256 age) internal returns (uint256 sid, uint256 price) {
        sid = _composeOnce().sid;
        _age(sid, age);
        price = ctl.priceOf(sid);
    }

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
            assertEq(address(ctl).balance, 0, "the controller holds nothing");
            (bool held,,,) = core.statementInfo(sid);
            assertFalse(held, "the core record is cleared");
            assertEq(core.heldStatements().length, n - 1);
            assertFalse(_held(sid));
            _solvent();
            vm.revertToState(snap);
        }
    }

    function test_buy_refundsTheExcess() public {
        (uint256 sid, uint256 price) = _buyAt(0);
        _pay(buyer, sid, price + 3 ether);
        assertEq(buyer.balance, 3 ether, "the excess came back");
        assertEq(address(ctl).balance, 0);
    }

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

    /// the price is read at the call: a buyer who pays the ask from before the anchor rose is refused, and pays the ask
    /// now (an anchor change moves the start of a held statement)
    function test_buy_paysTheAskOfTheBlock() public {
        (uint256 sid, uint256 price) = _buyAt(25 * H);
        assertEq(price, _cost(sid) * 12_500 / 10_000);
        _anchor(12_500);
        uint256 now_ = ctl.priceOf(sid);
        assertEq(now_, _cost(sid) * 16_250 / 10_000, "a raised anchor lifts the ask at once");
        vm.deal(buyer, price);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.Underpaid.selector);
        ctl.buy{value: price}(sid);
        _pay(buyer, sid, now_);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    function test_buy_atTheFloorAndBelowTheHardFloor() public {
        (uint256 sid, uint256 price) = _buyAt(200 * H);
        uint256 cost = _cost(sid);
        assertEq(price, cost * 7_500 / 10_000, "the ask at its floor equals the hard floor: allowed");
        // the controller floor falls below the hard floor: the quote and the payment are lifted to the hard floor
        // (review S-1, fixed), so the buy still clears at exactly the hard floor
        _saleSettings(15_000, 100_000, 100, 10_000, 25, 5_000);
        assertEq(ctl.floorBps(), 5_000);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the quote is the hard floor");
        _pay(buyer, sid, cost * 7_500 / 10_000);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertFalse(_held(sid));
    }

    function test_buy_aSecondBuyAndUnknownAndExitLaneRevert() public {
        _enterPhase2();
        (uint256 sid, uint256 price) = _buyAt(0);
        _pay(buyer, sid, price);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.buy{value: 100 ether}(sid);
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.buy{value: 100 ether}(sid + 500);
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        vm.prank(buyer);
        vm.expectRevert(IControllerV1.NotForSale.selector);
        ctl.buy{value: 100 ether}(xs);
    }

    /// the compaction of the held list: selling the first statement moves the last into its slot, and the moved
    /// statement still sells, exits and reports right
    function test_buy_theHeldListStaysRightAfterASaleOutOfTheMiddle() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        uint256 c = _another();
        uint256[] memory before_ = core.heldStatements();
        assertEq(before_.length, 3);
        _pay(buyer, a, ctl.priceOf(a));
        uint256[] memory after_ = core.heldStatements();
        assertEq(after_.length, 2);
        assertFalse(_held(a));
        assertTrue(_held(b));
        assertTrue(_held(c));
        (bool hb,, uint256 cb,) = core.statementInfo(b);
        (bool hc,, uint256 cc,) = core.statementInfo(c);
        assertTrue(hb && hc && cb != 0 && cc != 0);
        _pay(address(0xB0B2), c, ctl.priceOf(c));
        assertEq(core.heldStatements().length, 1);
        assertEq(core.heldStatements()[0], b);
        _pay(address(0xB0B3), b, ctl.priceOf(b));
        assertEq(core.heldStatements().length, 0);
        _solvent();
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
        emit ICore.StatementSoldTo(sid, buyer, floor, floor * 5_000 / 10_000);
        sc.sell{value: floor}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
        assertEq(address(core).balance - bal0, floor);
        assertEq(core.ethToBuyback() - bb0, floor * 5_000 / 10_000);
        assertEq(core.ethPot() - pot0, floor - floor * 5_000 / 10_000);
        assertEq(address(sc).balance, scBal, "the controller keeps nothing");
        _solvent();
    }

    /// a raised hard floor binds the controller's sale at once, a lowered one frees it
    function test_sellTo_followsTheHardFloorSetting() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 cost = _cost(sid);
        _floorBps(30_000);
        vm.expectRevert(ICore.BelowFloor.selector);
        sc.sell{value: cost * 29_999 / 10_000}(sid, buyer);
        vm.expectRevert(ICore.BelowFloor.selector);
        sc.sell{value: cost * 3 - 1}(sid, buyer);
        _floorBps(1_000);
        sc.sell{value: cost / 10}(sid, buyer);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

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

    function test_sellTo_exitLaneUnknownAndSoldRevert() public {
        _enterPhase2();
        uint256 sid = _composeOnce().sid;
        uint256[] memory ids = _credits(seller, 80);
        xt.mint(address(core), 5e19);
        core.skim();
        vm.prank(seller);
        core.sellForExitToken(ids);
        vm.fee(composeBasefee);
        core.composeExit();
        uint256 xs = STATEMENTS.supply();
        _install();
        vm.expectRevert(ICore.NotForSale.selector);
        sc.sell{value: 100 ether}(xs, buyer);
        vm.expectRevert(ICore.NotForSale.selector);
        sc.sell{value: 100 ether}(sid + 1000, buyer);
        assertEq(STATEMENTS.ownerOf(xs), address(core), "the exit lane statement stays");
        // a statement that was sold has no record any more
        sc.sell{value: _floorOf(sid)}(sid, buyer);
        vm.expectRevert(ICore.NotForSale.selector);
        sc.sell{value: 100 ether}(sid, buyer);
    }

    function test_sellTo_aSecondSaleOfTheSameStatementInOneTransactionFails() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 floor = _floorOf(sid);
        sc.sellTwice{value: floor * 2}(sid, buyer, floor, floor);
        assertFalse(sc.lastOk());
        assertEq(bytes4(sc.lastWhy()), ICore.NotForSale.selector);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    function test_sellTo_toTheZeroAddressRevertsAndToAContractWorks() public {
        uint256 sid = _composeOnce().sid;
        _install();
        uint256 floor = _floorOf(sid);
        vm.expectRevert();
        sc.sell{value: floor}(sid, address(0));
        assertEq(STATEMENTS.ownerOf(sid), address(core));
        assertTrue(_isHeld(sid));
        // a buyer without a receiver hook still gets it: the core uses a plain transfer
        sc.sell{value: floor}(sid, address(ctl));
        assertEq(STATEMENTS.ownerOf(sid), address(ctl));
    }

    /// the owner key can sell every statement at the floor through its own controller: the documented trust, and the
    /// only way a statement leaves. the eth goes to the pots and the owner gains nothing
    function test_sellTo_aControllerSellingAtTheFloorMovesEthOnlyIntoThePots() public {
        uint256 a = _composeOnce().sid;
        uint256 b = _another();
        _install();
        uint256 ownerEth = owner.balance;
        uint256 total = _floorOf(a) + _floorOf(b);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        sc.sell{value: _floorOf(a)}(a, address(sc));
        sc.sell{value: _floorOf(b)}(b, address(sc));
        assertEq(address(core).balance - bal0, total);
        assertEq((core.ethPot() - pot0) + (core.ethToBuyback() - bb0), total);
        assertEq(owner.balance, ownerEth);
        assertEq(core.heldStatements().length, 0);
        _solvent();
    }

    // ------------------------------------------------------------------ reentrancy

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
        assertTrue(rb.exitBlocked());
        assertEq(STATEMENTS.ownerOf(b), address(core), "the other statement is untouched");
        assertEq(core.ethPot() - pot0 + core.ethToBuyback() - bb0, price, "booked exactly once");
        _solvent();
    }

    function test_reenter_aBuyerThatRefusesTheRefundCanOnlyPayExactly() public {
        uint256 sid = _composeOnce().sid;
        RefundRefuser rr = new RefundRefuser(ctl);
        uint256 price = ctl.priceOf(sid);
        vm.deal(address(rr), price + 1 ether);
        (uint256 pot0, uint256 bb0, uint256 bal0) = _recordedBook();
        vm.expectRevert();
        rr.buy{value: price + 1 ether}(sid);
        (uint256 pot1, uint256 bb1, uint256 bal1) = _recordedBook();
        assertEq(pot1, pot0);
        assertEq(bb1, bb0);
        assertEq(bal1, bal0);
        assertEq(STATEMENTS.ownerOf(sid), address(core), "the failed buy changed nothing");
        rr.buy{value: price}(sid);
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
            floorBps: lc.sale.floorBps,
            anchorHalfLife: lc.sale.anchorHalfLife,
            anchorMinCost: lc.sale.anchorMinCost
        });
    }

    function _bad(bytes32 field) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IControllerV1.BadSetting.selector, field);
    }

    function test_settings_launchValues() public view {
        assertEq(lc.sale.markupBps, 15_000);
        assertEq(lc.sale.startCapBps, 100_000);
        assertEq(lc.sale.fastDecayBpsPerHour, 100);
        assertEq(lc.sale.kneeBps, 10_000);
        assertEq(lc.sale.slowDecayBpsPerHour, 25);
        assertEq(lc.sale.floorBps, 7_500);
        assertEq(lc.sale.anchorHalfLife, 7 days);
        assertEq(lc.sale.anchorMinCost, 0.1 ether);
        assertEq(abi.encode(Mainnet.defaultSale()), abi.encode(lc.sale), "the launch sale");
        assertEq(ctl.markupBps(), 15_000);
        assertEq(ctl.startCapBps(), 100_000);
        assertEq(ctl.fastDecayBpsPerHour(), 100);
        assertEq(ctl.kneeBps(), 10_000);
        assertEq(ctl.slowDecayBpsPerHour(), 25);
        assertEq(ctl.floorBps(), 7_500);
        assertEq(ctl.anchorHalfLife(), 7 days);
        assertEq(ctl.anchorMinCost(), 0.1 ether);
        assertEq(ctl.anchorBps(), 10_000, "the anchor starts at the cost");
        assertEq(ctl.storedAnchorBps(), 10_000);
        assertEq(ctl.anchorTime(), block.timestamp);
        assertEq(ctl.startBps(), 15_000);
    }

    function test_settings_boundsOfEverySetter() public {
        vm.startPrank(owner);
        // markupBps 10_000 to 40_000, at most the cap
        ctl.setMarkupBps(10_000);
        vm.expectRevert(_bad("markupBps"));
        ctl.setMarkupBps(9_999);
        ctl.setMarkupBps(40_000);
        vm.expectRevert(_bad("markupBps"));
        ctl.setMarkupBps(40_001);
        // startCapBps from the markup and the knee to 200_000
        vm.expectRevert(_bad("startCapBps"));
        ctl.setStartCapBps(39_999);
        ctl.setStartCapBps(40_000);
        ctl.setStartCapBps(200_000);
        vm.expectRevert(_bad("startCapBps"));
        ctl.setStartCapBps(200_001);
        // fastDecayBpsPerHour 1 to 10_000
        vm.expectRevert(_bad("fastDecayBpsPerHour"));
        ctl.setFastDecayBpsPerHour(0);
        ctl.setFastDecayBpsPerHour(1);
        ctl.setFastDecayBpsPerHour(10_000);
        vm.expectRevert(_bad("fastDecayBpsPerHour"));
        ctl.setFastDecayBpsPerHour(10_001);
        // slowDecayBpsPerHour 1 to 10_000
        vm.expectRevert(_bad("slowDecayBpsPerHour"));
        ctl.setSlowDecayBpsPerHour(0);
        ctl.setSlowDecayBpsPerHour(1);
        ctl.setSlowDecayBpsPerHour(10_000);
        vm.expectRevert(_bad("slowDecayBpsPerHour"));
        ctl.setSlowDecayBpsPerHour(10_001);
        // kneeBps from the floor (7_500) to the cap
        vm.expectRevert(_bad("kneeBps"));
        ctl.setKneeBps(7_499);
        ctl.setKneeBps(7_500);
        ctl.setKneeBps(200_000);
        vm.expectRevert(_bad("kneeBps"));
        ctl.setKneeBps(200_001);
        // floorBps 1_000 to the smaller of 10_000 and the knee
        vm.expectRevert(_bad("floorBps"));
        ctl.setFloorBps(999);
        ctl.setFloorBps(1_000);
        ctl.setFloorBps(10_000);
        vm.expectRevert(_bad("floorBps"));
        ctl.setFloorBps(10_001);
        ctl.setKneeBps(10_000);
        vm.expectRevert(_bad("floorBps"));
        ctl.setFloorBps(10_001);
        ctl.setKneeBps(200_000);
        // anchorBps 10_000 to the cap
        vm.expectRevert(_bad("anchorBps"));
        ctl.setAnchorBps(9_999);
        ctl.setAnchorBps(10_000);
        ctl.setAnchorBps(200_000);
        vm.expectRevert(_bad("anchorBps"));
        ctl.setAnchorBps(200_001);
        // anchorHalfLife 1 day to 90 days
        vm.expectRevert(_bad("anchorHalfLife"));
        ctl.setAnchorHalfLife(1 days - 1);
        ctl.setAnchorHalfLife(1 days);
        ctl.setAnchorHalfLife(90 days);
        vm.expectRevert(_bad("anchorHalfLife"));
        ctl.setAnchorHalfLife(90 days + 1);
        // anchorMinCost 0 to 10 ether
        ctl.setAnchorMinCost(0);
        ctl.setAnchorMinCost(10 ether);
        vm.expectRevert(_bad("anchorMinCost"));
        ctl.setAnchorMinCost(10 ether + 1);
        vm.expectRevert(_bad("anchorMinCost"));
        ctl.setAnchorMinCost(type(uint128).max);
        vm.stopPrank();
        assertEq(ctl.anchorMinCost(), 10 ether);
        assertEq(ctl.anchorHalfLife(), 90 days);
        assertEq(ctl.markupBps(), 40_000);
        assertEq(ctl.startCapBps(), 200_000);
        assertEq(ctl.fastDecayBpsPerHour(), 10_000);
        assertEq(ctl.slowDecayBpsPerHour(), 10_000);
        assertEq(ctl.kneeBps(), 200_000);
        assertEq(ctl.floorBps(), 10_000);
        assertEq(ctl.anchorBps(), 200_000);
        assertEq(ctl.startBps(), 200_000, "800_000 is held at the cap");
    }

    /// a cap set below the anchor lowers the anchor to it, with the anchor event. a cap at or above the anchor leaves it
    function test_settings_loweringTheCapBelowTheAnchorLowersTheAnchor() public {
        vm.startPrank(owner);
        ctl.setAnchorBps(80_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.StartCapBpsSet(60_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorBpsSet(60_000);
        ctl.setStartCapBps(60_000);
        assertEq(ctl.anchorBps(), 60_000);
        assertEq(ctl.startBps(), 60_000);
        vm.recordLogs();
        ctl.setStartCapBps(60_000);
        ctl.setStartCapBps(90_000);
        assertEq(vm.getRecordedLogs().length, 2, "only the cap events");
        assertEq(ctl.anchorBps(), 60_000);
        vm.stopPrank();
    }

    /// the clamp reads the anchor now: a cap above the decayed anchor leaves the stored anchor and its time, a cap below
    /// it stores the cap with the time of the call
    function test_settings_capClampUsesTheDecayedAnchor() public {
        vm.prank(owner);
        ctl.setAnchorBps(80_000);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 7 days);
        assertEq(ctl.anchorBps(), 45_000, "70_000 of excess halved once");
        vm.startPrank(owner);
        ctl.setStartCapBps(60_000);
        assertEq(ctl.storedAnchorBps(), 80_000, "the cap is above the decayed anchor: no change");
        assertEq(ctl.anchorTime(), t0);
        assertEq(ctl.anchorBps(), 45_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorBpsSet(40_000);
        ctl.setStartCapBps(40_000);
        vm.stopPrank();
        assertEq(ctl.storedAnchorBps(), 40_000);
        assertEq(ctl.anchorTime(), t0 + 7 days);
        assertEq(ctl.anchorBps(), 40_000);
    }

    function test_settings_eventsAndValues() public {
        vm.startPrank(owner);
        vm.expectEmit(address(ctl));
        emit IControllerV1.MarkupBpsSet(12_000);
        ctl.setMarkupBps(12_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.StartCapBpsSet(150_000);
        ctl.setStartCapBps(150_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.FastDecayBpsPerHourSet(200);
        ctl.setFastDecayBpsPerHour(200);
        vm.expectEmit(address(ctl));
        emit IControllerV1.SlowDecayBpsPerHourSet(50);
        ctl.setSlowDecayBpsPerHour(50);
        vm.expectEmit(address(ctl));
        emit IControllerV1.KneeBpsSet(12_000);
        ctl.setKneeBps(12_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.FloorBpsSet(8_000);
        ctl.setFloorBps(8_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorBpsSet(11_000);
        ctl.setAnchorBps(11_000);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorHalfLifeSet(3 days);
        ctl.setAnchorHalfLife(3 days);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorMinCostSet(0.25 ether);
        ctl.setAnchorMinCost(0.25 ether);
        vm.stopPrank();
        assertEq(ctl.markupBps(), 12_000);
        assertEq(ctl.startCapBps(), 150_000);
        assertEq(ctl.fastDecayBpsPerHour(), 200);
        assertEq(ctl.slowDecayBpsPerHour(), 50);
        assertEq(ctl.kneeBps(), 12_000);
        assertEq(ctl.floorBps(), 8_000);
        assertEq(ctl.anchorBps(), 11_000);
        assertEq(ctl.anchorHalfLife(), 3 days);
        assertEq(ctl.anchorMinCost(), 0.25 ether);
        assertEq(ctl.startBps(), 13_200);
    }

    /// only the live owner of the core: not the deployer, not a keeper, not the controller itself
    function test_settings_onlyTheCoreOwner() public {
        address[4] memory who = [deployer, keeper, address(ctl), address(0x5757)];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setMarkupBps(12_000);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setStartCapBps(150_000);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setFastDecayBpsPerHour(200);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setSlowDecayBpsPerHour(50);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setKneeBps(12_000);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setFloorBps(8_000);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setAnchorBps(11_000);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setAnchorHalfLife(3 days);
            vm.expectRevert(IControllerV1.OnlyOwner.selector);
            ctl.setAnchorMinCost(0.25 ether);
            vm.stopPrank();
        }
        assertEq(ctl.anchorHalfLife(), 7 days);
        assertEq(ctl.anchorMinCost(), 0.1 ether);
        assertEq(ctl.markupBps(), 15_000);
        assertEq(ctl.anchorBps(), 10_000);
    }

    /// the setters follow `core.owner()`: after a handover the new owner sets, the old owner is refused
    function test_settings_followACoreHandover() public {
        address heir = address(0xEE12);
        vm.prank(owner);
        core.transferOwnership(heir);
        vm.prank(heir);
        core.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        ctl.setAnchorBps(12_000);
        vm.prank(heir);
        ctl.setAnchorBps(12_000);
        assertEq(ctl.anchorBps(), 12_000);
    }

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
        s.kneeBps = s.floorBps - 1;
        vm.expectRevert(_bad("kneeBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.kneeBps = s.startCapBps + 1;
        vm.expectRevert(_bad("kneeBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.floorBps = 999;
        vm.expectRevert(_bad("floorBps"));
        Prod.newController(address(core), s);
        s = _fresh();
        s.floorBps = 10_001;
        vm.expectRevert(_bad("floorBps"));
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

    /// a controller the owner installs later is governed by the same live owner
    function test_settings_aNewControllerFollowsTheSameOwner() public {
        IControllerV1 c2 = Prod.newController(address(core), lc.sale);
        _setController(address(c2));
        vm.prank(owner);
        c2.setFastDecayBpsPerHour(200);
        assertEq(c2.fastDecayBpsPerHour(), 200);
        vm.prank(address(0x5757));
        vm.expectRevert(IControllerV1.OnlyOwner.selector);
        c2.setFastDecayBpsPerHour(200);
    }
}

contract SaleAnchorTest is SaleBase {
    address internal buyer = address(0xB0B);
    uint128 internal constant LAUNCH_MIN_COST = 0.1 ether;

    /// a page at the fixture rate costs under the launch `anchorMinCost`. the anchor tests run with the minimum at 0 and
    /// the tests of the minimum set it
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        ctl.setAnchorMinCost(0);
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

    /// a sale below the anchor leaves the stored anchor, its time and the event log unchanged
    function test_anchor_aSaleBelowTheAnchorLeavesIt() public {
        uint256 sid = _composeN(1)[0];
        _age(sid, 90 * H);
        uint256 price = ctl.priceOf(sid);
        assertEq(price, _cost(sid) * 9_000 / 10_000);
        uint256 t0 = ctl.anchorTime();
        vm.recordLogs();
        _pay(buyer, sid, price);
        assertEq(_moved(vm.getRecordedLogs()), 0, "no AnchorMoved");
        assertEq(ctl.storedAnchorBps(), 10_000);
        assertEq(ctl.anchorTime(), t0, "no checkpoint");
        assertEq(ctl.anchorBps(), 10_000);
        assertEq(ctl.startBps(), 15_000);
    }

    /// the review of d77b82c (F1): with an empty pot the engine pays 1 wei per credit, so a statement of about 80 wei is
    /// composed and bought at its start price. four rounds leave the anchor, its time and the fresh start price unchanged
    function test_anchor_dustStatementsLeaveTheAnchor() public {
        vm.prank(owner);
        ctl.setAnchorMinCost(LAUNCH_MIN_COST);
        assertEq(core.ethPot(), 0, "the pot is empty");
        address attacker = address(0xA77);
        uint256 t0 = ctl.anchorTime();
        for (uint256 r; r < 4; ++r) {
            uint256[] memory ids = _credits(attacker, 80);
            for (uint256 i; i < 80; ++i) {
                vm.deal(attacker, attacker.balance + 1);
                vm.prank(attacker);
                (bool ok,) = address(core).call{value: 1}("");
                assertTrue(ok);
                core.skim();
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
            assertLt(_cost(sid), 1_000, "80 credits at 1 wei each, plus the page remainder");
            uint256 price = ctl.priceOf(sid);
            assertEq(price, _cost(sid) * 15_000 / 10_000, "the start price");
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

    /// a statement whose cost equals `anchorMinCost` moves the anchor. one wei less leaves it
    function test_anchor_theMinimumCostIsInclusive() public {
        uint256[] memory sids = _composeN(2);
        uint128 c0 = uint128(_cost(sids[0]));
        uint128 c1 = uint128(_cost(sids[1]));
        vm.prank(owner);
        ctl.setAnchorMinCost(c0 + 1);
        uint256 t0 = ctl.anchorTime();
        _buyAtStart(sids[0]);
        assertEq(ctl.storedAnchorBps(), 10_000, "one wei under the minimum");
        assertEq(ctl.anchorTime(), t0);
        vm.prank(owner);
        ctl.setAnchorMinCost(c1);
        _buyAtStart(sids[1]);
        assertEq(ctl.storedAnchorBps(), 12_500, "at the minimum");
        assertEq(ctl.anchorTime(), block.timestamp);
    }

    /// at the launch minimum a page of 0.114 eth moves the anchor and a page of 0.078 eth leaves it. a minimum of 0 lets
    /// any cost move it
    function test_anchor_launchMinimumAndZero() public {
        uint256[] memory sids = _composeN(2);
        vm.prank(owner);
        ctl.setAnchorMinCost(LAUNCH_MIN_COST);
        assertGe(_cost(sids[0]), LAUNCH_MIN_COST);
        assertLt(_cost(sids[1]), LAUNCH_MIN_COST);
        _buyAtStart(sids[0]);
        assertEq(ctl.storedAnchorBps(), 12_500, "a page above the minimum");
        uint256 at = ctl.anchorTime();
        _buyAtStart(sids[1]);
        assertEq(ctl.storedAnchorBps(), 12_500, "a page under the minimum");
        assertEq(ctl.anchorTime(), at);
        uint256 sid = _another();
        vm.prank(owner);
        ctl.setAnchorMinCost(0);
        _buyAtStart(sid);
        assertEq(ctl.storedAnchorBps(), 15_625, "a minimum of 0");
    }

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

    /// the start price of a new statement follows the decayed anchor
    function test_anchor_startPriceFollowsTheDecay() public {
        _anchor(30_000);
        assertEq(ctl.startBps(), 45_000);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(ctl.startBps(), 30_000, 2, "1.5 times 20_000");
        vm.warp(block.timestamp + 7 days * 20);
        assertEq(ctl.startBps(), 15_000, "1.5 times 10_000");
    }

    /// a held statement follows the anchor down as it decays: the price is the curve from the live start price
    function test_anchor_anOpenListingFollowsTheDecayingAnchor() public {
        uint256 sid = _composeN(1)[0];
        uint256 cost = _cost(sid);
        _anchor(30_000);
        _age(sid, 0);
        assertEq(ctl.priceOf(sid), cost * 45_000 / 10_000);
        _age(sid, 52 * H + 30 minutes);
        uint256 anchor = ctl.anchorBps();
        assertApproxEqAbs(anchor, 10_000 + 20_000 * 8_053 / 10_000, 2, "2^(-52.5 / 168) of the excess");
        assertEq(ctl.priceOf(sid), _curve(cost, anchor * 15_000 / 10_000, 10_000, 100, 25, 7_500, 52 * H + 30 minutes));
        assertLt(
            ctl.priceOf(sid),
            _curve(cost, 45_000, 10_000, 100, 25, 7_500, 52 * H + 30 minutes),
            "below the curve of an anchor that did not decay"
        );
        _age(sid, 1_000 * H);
        assertEq(ctl.priceOf(sid), cost * 7_500 / 10_000, "the end of the curve is the floor");
    }

    /// a sale above the decayed anchor moves it halfway from the decayed value, and the stored anchor takes the time
    function test_anchor_aSaleAboveTheDecayedAnchorMovesItHalfWay() public {
        _composeN(1);
        _anchor(30_000);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(ctl.anchorBps(), 20_000, 1);
        uint256 sid = _another();
        uint256 cost = _cost(sid);
        uint256 effective = ctl.anchorBps();
        uint256 price = ctl.priceOf(sid);
        assertEq(price, cost * ctl.startBps() / 10_000);
        uint256 saleBps = (price * 10_000 + cost - 1) / cost;
        assertGt(saleBps, effective);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorMoved(sid, saleBps, uint32((effective + saleBps) / 2));
        _pay(buyer, sid, price);
        assertEq(ctl.storedAnchorBps(), (effective + saleBps) / 2);
        assertEq(ctl.anchorTime(), block.timestamp);
        assertEq(ctl.anchorBps(), (effective + saleBps) / 2);
        assertApproxEqAbs(ctl.anchorBps(), 25_000, 2, "halfway between 20_000 and 30_000");
    }

    /// changing the half life stores the anchor now first, so the new rate applies to the time after the change
    function test_anchor_halfLifeChangeCheckpoints() public {
        _anchor(30_000);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 7 days);
        vm.prank(owner);
        ctl.setAnchorHalfLife(14 days);
        assertEq(ctl.anchorTime(), t0 + 7 days);
        assertApproxEqAbs(ctl.storedAnchorBps(), 20_000, 1);
        assertApproxEqAbs(ctl.anchorBps(), 20_000, 1, "the value at the change is unchanged");
        vm.warp(t0 + 7 days + 14 days);
        assertApproxEqAbs(ctl.anchorBps(), 15_000, 1, "one new half life after the change");
        vm.prank(owner);
        ctl.setAnchorHalfLife(1 days);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(ctl.anchorBps(), 12_500, 1, "one new half life of 1 day");
    }

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

    /// four sales at the start price in a row. integer math: the start is the anchor times 1.5 rounded down, the anchor
    /// the mean of the old anchor and the sale price rounded down
    function test_anchor_fourSalesAtTheStart() public {
        uint256[] memory sids = _composeN(4);
        uint256[4] memory start = [uint256(15_000), 18_750, 23_437, 29_296];
        uint256[4] memory anchor = [uint256(12_500), 15_625, 19_531, 24_413];
        assertEq(ctl.anchorBps(), 10_000);
        for (uint256 i; i < 4; ++i) {
            assertEq(ctl.startBps(), start[i], "start before the sale");
            (uint256 price, uint256 cost) = _buyAtStart(sids[i]);
            assertEq(price, cost * start[i] / 10_000, "the sale is at the start price");
            assertEq(ctl.anchorBps(), anchor[i], "anchor after the sale");
        }
    }

    /// a held statement follows the anchor: its price rises when another statement sells above the anchor, at every age
    function test_anchor_anOpenListingFollowsTheAnchor() public {
        uint256[] memory sids = _composeN(2);
        uint256 cost = _cost(sids[1]);
        _age(sids[1], 0);
        uint256 before0 = ctl.priceOf(sids[1]);
        _age(sids[1], 52 * H + 30 minutes);
        uint256 before1 = ctl.priceOf(sids[1]);
        assertEq(before0, cost * 15_000 / 10_000);
        assertEq(before1, cost * 99_375 / 100_000, "9_937.5 bps: 2.5 hours into the slow stage");
        _buyAtStart(sids[0]);
        assertEq(ctl.anchorBps(), 12_500);
        _age(sids[1], 0);
        assertEq(ctl.priceOf(sids[1]), cost * 18_750 / 10_000, "the start follows the anchor");
        assertGt(ctl.priceOf(sids[1]), before0);
        // 52.5 hours later the anchor 12_500 has decayed to 12_013 (7 day half life): start 18_019, and the price is the
        // start less 52.5 hours of 100 bps: 18_019 - 5_250 = 12_769
        _age(sids[1], 52 * H + 30 minutes);
        assertApproxEqAbs(ctl.anchorBps(), 12_013, 1);
        assertEq(
            ctl.priceOf(sids[1]),
            _curve(cost, ctl.anchorBps() * 15_000 / 10_000, 10_000, 100, 25, 7_500, 52 * H + 30 minutes),
            "and so does the rest of the curve"
        );
        assertApproxEqAbs(ctl.priceOf(sids[1]), cost * 12_769 / 10_000, cost * 3 / 10_000);
        assertGt(ctl.priceOf(sids[1]), before1);
        _age(sids[1], 1_000 * H);
        assertEq(ctl.priceOf(sids[1]), cost * 7_500 / 10_000, "the end of the curve is the floor");
    }

    /// the owner lowers the anchor back and the held statement follows it down
    function test_anchor_theOwnerCorrectsTheAnchor() public {
        uint256[] memory sids = _composeN(2);
        _buyAtStart(sids[0]);
        assertEq(ctl.anchorBps(), 12_500);
        _anchor(10_000);
        _age(sids[1], 0);
        assertEq(ctl.priceOf(sids[1]), _cost(sids[1]) * 15_000 / 10_000);
    }

    /// the start is held at the cap, and a sale at the cap keeps the start there
    function test_anchor_startCapHoldsAfterSales() public {
        uint256[] memory sids = _composeN(2);
        _anchor(80_000);
        assertEq(ctl.startBps(), 100_000);
        (uint256 price, uint256 cost) = _buyAtStart(sids[0]);
        assertEq(price, cost * 10);
        assertEq(ctl.anchorBps(), 90_000, "the mean of 80_000 and 100_000");
        assertEq(ctl.startBps(), 100_000);
    }

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

    /// the sale is recorded at the asking price, not at `msg.value`: the excess is refunded and does not move the anchor
    function test_anchor_buyRecordsTheAskNotMsgValue() public {
        uint256 sid = _composeN(1)[0];
        _age(sid, 0);
        uint256 price = ctl.priceOf(sid);
        vm.expectEmit(address(ctl));
        emit IControllerV1.AnchorMoved(sid, 15_000, 12_500);
        _pay(buyer, sid, price + 7 ether);
        assertEq(buyer.balance, 7 ether, "the excess came back");
        assertEq(address(ctl).balance, 0);
        assertEq(ctl.anchorBps(), 12_500, "recorded at the asking price");
    }

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
contract SaleDecayTest is SaleBase {
    /// a start of 300 percent (markup 30_000 on the anchor floor of 10_000): 1 percent an hour for 200 hours to the knee,
    /// then 0.25 percent an hour for 100 hours to the floor
    function test_decay_startAt30000() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        vm.prank(owner);
        ctl.setMarkupBps(30_000);
        assertEq(ctl.startBps(), 30_000);
        uint256[7] memory t = [uint256(0), 100 * H, 200 * H, 240 * H, 250 * H, 300 * H, 400 * H];
        uint256[7] memory bps = [uint256(30_000), 20_000, 10_000, 9_000, 8_750, 7_500, 7_500];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            assertEq(ctl.priceOf(sid), cost * bps[i] / 10_000, "ask");
            assertEq(_raw(sid), cost * bps[i] / 10_000, "controller price");
        }
        _age(sid, 200 * H - 1);
        assertGt(ctl.priceOf(sid), cost, "one second before the knee");
        _age(sid, 300 * H - 1);
        assertGt(ctl.priceOf(sid), cost * 7_500 / 10_000, "one second before the floor");
    }

    /// an anchor of 20_000 gives the same start at listing, 30_000. the anchor then decays with its half life and the
    /// start with it, so the price at a later age is the curve of the live start
    function test_decay_anchorStartFollowsTheDecayingAnchor() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _anchor(20_000);
        _age(sid, 0);
        assertEq(ctl.startBps(), 30_000);
        assertEq(ctl.priceOf(sid), cost * 30_000 / 10_000);
        _age(sid, 100 * H);
        assertLt(ctl.startBps(), 30_000, "the anchor decayed");
        assertEq(ctl.priceOf(sid), _curve(cost, ctl.startBps(), 10_000, 100, 25, 7_500, 100 * H));
    }

    /// a start at or below the knee falls at the slow rate from the first second
    function test_decay_startBelowTheKneeFallsSlow() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        vm.prank(owner);
        ctl.setKneeBps(20_000);
        assertEq(ctl.startBps(), 15_000);
        uint256[5] memory t = [uint256(0), 4 * H, 40 * H, 300 * H, 301 * H];
        uint256[5] memory bps = [uint256(15_000), 14_900, 14_000, 7_500, 7_500];
        for (uint256 i; i < t.length; ++i) {
            _age(sid, t[i]);
            assertEq(_raw(sid), cost * bps[i] / 10_000, "knee above the start");
        }
        // the markup lowered to the knee itself
        vm.startPrank(owner);
        ctl.setKneeBps(10_000);
        ctl.setMarkupBps(10_000);
        vm.stopPrank();
        assertEq(ctl.startBps(), 10_000);
        uint256[4] memory t2 = [uint256(0), 40 * H, 100 * H, 500 * H];
        uint256[4] memory bps2 = [uint256(10_000), 9_000, 7_500, 7_500];
        for (uint256 i; i < t2.length; ++i) {
            _age(sid, t2[i]);
            assertEq(_raw(sid), cost * bps2[i] / 10_000, "start at the knee");
        }
    }

    /// each of the four settings moves a held statement to the value the new rule gives for its age
    function test_decay_settingsMoveAnOpenListingAtOnce() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 60 * H);
        assertEq(ctl.priceOf(sid), cost * 9_750 / 10_000, "launch rule: 10 hours past the knee at 25 bps an hour");
        vm.startPrank(owner);
        ctl.setSlowDecayBpsPerHour(50);
        assertEq(ctl.priceOf(sid), cost * 9_500 / 10_000, "slow 50: 10 hours at 50");
        ctl.setFastDecayBpsPerHour(200);
        assertEq(ctl.priceOf(sid), cost * 8_250 / 10_000, "fast 200: the knee is at hour 25, 35 hours at 50");
        ctl.setKneeBps(12_000);
        assertEq(ctl.priceOf(sid), cost * 9_750 / 10_000, "knee 12_000: reached at hour 15, 45 hours at 50");
        ctl.setFloorBps(9_900);
        assertEq(ctl.priceOf(sid), cost * 9_900 / 10_000, "floor 9_900 lifts it");
        ctl.setFloorBps(7_500);
        ctl.setKneeBps(10_000);
        ctl.setFastDecayBpsPerHour(100);
        ctl.setSlowDecayBpsPerHour(25);
        vm.stopPrank();
        assertEq(ctl.priceOf(sid), cost * 9_750 / 10_000, "back to the launch rule");
        assertEq(_raw(sid), ctl.priceOf(sid));
    }

    /// `buy` pays the live rule
    function test_decay_buyPaysTheLiveRule() public {
        uint256 sid = _composeOnce().sid;
        uint256 cost = _cost(sid);
        _age(sid, 60 * H);
        vm.prank(owner);
        ctl.setSlowDecayBpsPerHour(50);
        assertEq(ctl.priceOf(sid), cost * 9_500 / 10_000);
        address buyer = address(0xB0B);
        _pay(buyer, sid, cost * 9_500 / 10_000);
        assertEq(STATEMENTS.ownerOf(sid), buyer);
    }

    /// the setter order that reaches any valid combination: the cap rises before the knee, the knee falls before the
    /// cap, the floor falls before the knee and rises after it
    function test_decay_everyValidCombinationIsReachable() public {
        vm.startPrank(owner);
        // up: the knee over the cap needs the cap first, and the floor over the knee needs the knee first
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("kneeBps")));
        ctl.setKneeBps(150_000);
        ctl.setStartCapBps(150_000);
        ctl.setKneeBps(150_000);
        ctl.setFloorBps(10_000);
        // down: the cap under the knee needs the knee first, and the knee under the floor needs the floor first
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("startCapBps")));
        ctl.setStartCapBps(15_000);
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("kneeBps")));
        ctl.setKneeBps(9_999);
        ctl.setFloorBps(1_000);
        ctl.setKneeBps(1_000);
        ctl.setStartCapBps(15_000);
        assertEq(ctl.kneeBps(), 1_000);
        assertEq(ctl.floorBps(), 1_000);
        assertEq(ctl.startCapBps(), 15_000);
        // the floor over the knee is refused
        vm.expectRevert(abi.encodeWithSelector(IControllerV1.BadSetting.selector, bytes32("floorBps")));
        ctl.setFloorBps(1_001);
        // and the knee at the cap, the floor at 10_000 is reachable again
        ctl.setKneeBps(15_000);
        ctl.setFloorBps(10_000);
        vm.stopPrank();
        assertEq(ctl.kneeBps(), 15_000);
        assertEq(ctl.floorBps(), 10_000);
    }

    /// answers the controller's reads of the Core for the price fuzz: the cost and the compose time of any statement
    StatementInfoStub internal stub;

    /// a controller with random valid settings and a random anchor, created after `warp` seconds so the anchor has not decayed
    function _decayControllerFuzz(uint256[8] memory x, uint256 warp)
        internal
        returns (IControllerV1 c, Sale memory k, uint256 anchor)
    {
        vm.warp(block.timestamp + warp);
        stub = new StatementInfoStub(owner);
        k.markupBps = uint16(bound(x[0], 10_000, 40_000));
        k.startCapBps = uint32(bound(x[1], k.markupBps, 200_000));
        k.floorBps = uint16(bound(x[2], 1_000, 10_000));
        k.kneeBps = uint32(bound(x[3], k.floorBps, k.startCapBps));
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
            cost, c.startBps(), k.kneeBps, k.fastDecayBpsPerHour, k.slowDecayBpsPerHour, k.floorBps, age
        );
    }

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
        assertGe(p2, cost * k.floorBps / 10_000, "at least the floor");
        assertEq(_at(c, cost, 0), cost * c.startBps() / 10_000, "age zero is the start");
        assertEq(p1, _closedForm(c, k, cost, a1));
        assertEq(p2, _closedForm(c, k, cost, age2));
    }

    /// the price falls by at most one second of the faster rate, plus one unit of the rounding, from one second to the next
    function testFuzz_decay_continuousPerSecond(uint256[8] memory x, uint128 cost_, uint32 age_) public {
        (IControllerV1 c, Sale memory k,) = _decayControllerFuzz(x, uint256(age_) + 2);
        uint256 cost = bound(cost_, 1, type(uint128).max);
        uint256 p0 = _at(c, cost, age_);
        uint256 p1 = _at(c, cost, uint256(age_) + 1);
        uint256 rate = k.fastDecayBpsPerHour > k.slowDecayBpsPerHour ? k.fastDecayBpsPerHour : k.slowDecayBpsPerHour;
        assertLe(p1, p0);
        assertLe(p0 - p1, cost * (rate + 1) / (3600 * 10_000) + 1);
    }

    /// the slow stage follows the exact line from the real time the knee is reached, within one unit of 1/3600 bps
    function testFuzz_decay_slowStageIsTheExactLine(uint256[8] memory x, uint128 cost_, uint32 age_) public {
        (IControllerV1 c, Sale memory k,) = _decayControllerFuzz(x, uint256(age_) + 1);
        uint256 cost = bound(cost_, 1, type(uint128).max);
        uint256 base = (c.startBps() < k.kneeBps ? c.startBps() : k.kneeBps) * 3600;
        uint256 span = c.startBps() > k.kneeBps ? (c.startBps() - k.kneeBps) * 3600 : 0;
        uint256 f = k.fastDecayBpsPerHour;
        vm.assume(uint256(age_) * f > span);
        uint256 drop = uint256(k.slowDecayBpsPerHour) * (uint256(age_) * f - span);
        vm.assume(base * f > drop + uint256(k.floorBps) * 3600 * f);
        uint256 ideal = cost * (base * f - drop) / (f * 3600 * 10_000);
        uint256 got = _at(c, cost, age_);
        assertLe(got, ideal, "rounding goes down");
        assertLe(ideal - got, cost / (3600 * 10_000) + 1, "by less than one unit");
    }
}
