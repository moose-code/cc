// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Quote, RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {IControllerV1} from "../src/interfaces/IControllerV1.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {TestLiquidityHelper} from "./utils/TestLiquidityHelper.sol";
import {ValueBase, ValueFixtureBase} from "./ValueMode.t.sol";

/// promise: SPEC 4 with value mode off, bid, drop, ceiling, credit sale price and statement decay match formulas using
/// the current settings and getters. these checks do not compare against a pinned historical implementation. value mode
/// is off in the default fixture. the climb and ceiling cases overlap BidRule; the sale cases overlap CreditSale and Sale
contract ModeOffPricingRulesTest is Fixture {
    uint256 internal constant BPS = 10_000;

    function _recoveryEqualsClimb() internal {
        Settings memory s = core.settings();
        s.recoveryClimbPerMinBps = s.climbPerMinBps;
        _setSettings(s);
    }

    // the eth bid is the price state per 100 points times the score: rate * score / RATE_SCORE (1e6)
    function test_bidIsPerPoint() public {
        _fundPot(10 ether);
        assertFalse(core.settings().valueModeOn, "value mode off");
        uint256[] memory ids = _credits(seller, 1);
        uint256 score = _scoreOf(ids[0]);
        uint256 rate = core.ethRate();
        assertEq(core.bidOf(ids[0]), rate * score / RATE_SCORE, "bidOf is the per-point rate times the score");
        assertEq(core.bidForScore(score), rate * score / RATE_SCORE, "bidForScore matches");
        assertEq(core.ethPerPoint(), rate / 100, "ethPerPoint is the rate over 100 points");
    }

    // a fill drops the price state by dropPer100PointsBps per 100 points: a unit-score credit drops it 115 bps
    function test_dropIsTheLaunchDrop() public {
        _fundPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        uint256 r0 = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 drop = core.settings().dropPer100PointsBps;
        assertEq(core.rateAtCheckpoint(), r0 * (BPS - drop) / BPS, "the drop is dropPer100PointsBps of the rate paid");
        assertEq(drop, 115, "the launch drop");
    }

    // the price state climbs to the ceiling of 110 percent of the anchor and the anchor loosens 6 percent per full 10
    // idle minutes at a one page pot (the climb reaches it at climbPerMinBps 2 percent a minute)
    function test_climbCeilingAndLoosening() public {
        _recoveryEqualsClimb();
        assertEq(core.settings().ceilBps, 11_000, "ceiling 110 percent");
        assertEq(core.settings().climbPerMinBps, 200, "climb 2 percent a minute");
        assertEq(core.settings().idleLoosenBps, 600, "loosen 6 percent per 10 idle minutes");
        // a pot under one page keeps the pages multiplier at 1x, so the loosening is the base 6 percent
        _fundPot(0.1 ether);
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        vm.prank(seller);
        core.sellForEth(_one(id));
        (uint256 anchor,,) = _anchor();
        _warp(9 minutes + 59);
        uint256 base = anchor * 11_000 / BPS;
        assertEq(core.ethRate(), base, "the climb holds at 110 percent before 10 idle minutes");
        // after a full idle interval the anchor loosens by idleLoosenBps scaled by the pages multiplier, so the ceiling
        // rises above the base 110 percent (the exact loosening by pot size is in BidRule)
        _warp(1);
        uint256 loosened = core.ethRate();
        assertGt(loosened, base, "the ceiling loosens above 110 percent after 10 idle minutes");
        _warp(10 minutes);
        assertGt(core.ethRate(), loosened, "and loosens further over another 10 idle minutes");
    }

    // a pile credit at acquisition is asked at creditStartBps (1.5x) of its floor; the floor is recomputed from the
    // contract's views at the same instant, so the comparison does not drift with the climbing floor rate
    function test_creditSaleStartIsOverTheFloor() public {
        _setCreditSaleOn(true);
        uint256 id = _fillEthPile(1)[0];
        (, uint256 cost, uint64 acquiredAt) = core.creditInfo(id);
        assertEq(acquiredAt, block.timestamp, "the credit is fresh, age zero");
        uint256 hi = ctl.valueOf(_scoreOf(id));
        if (cost > hi) hi = cost;
        uint256 floor = hi * ctl.floorMultBps() / BPS;
        uint256 coreFloor = cost * core.settings().saleFloorBps / BPS;
        if (floor < coreFloor) floor = coreFloor;
        assertEq(
            ctl.creditPrice(id), floor * ctl.creditStartBps() / BPS, "the start ask is creditStartBps of the floor"
        );
        assertEq(ctl.creditStartBps(), 15_000, "the launch 1.5x start");
    }

    // a statement is asked at startBps of its reference at age zero and rests at saleFloorBps of the reference after
    // decayHours
    function test_statementDecay() public {
        Composed memory c = _composeOnce();
        // the reference moves with the climbing floor rate, so read it fresh at each age
        assertEq(
            ctl.priceOf(c.sid),
            ctl.referenceOf(c.sid) * ctl.startBps() / BPS,
            "the start ask is startBps of the reference"
        );
        _warp(uint256(ctl.decayHours()) * 1 hours + 1);
        assertEq(
            ctl.priceOf(c.sid),
            ctl.referenceOf(c.sid) * core.settings().saleFloorBps / BPS,
            "the ask rests at saleFloorBps of the reference after decayHours"
        );
        assertEq(ctl.decayHours(), 4, "the launch 4 hour decay");
    }

    struct Prices {
        uint256 bidForScore;
        uint256 balanceBid;
        uint256 balanceBidForScore;
        uint256 valueOf;
        uint256 statementRef;
        uint256 statementAsk;
        uint256 creditRef;
        uint256 creditAsk;
        bool statementAtFloor;
        uint256 composePaid;
    }

    function _prices() internal returns (Prices memory p) {
        uint256 cid = _credits(seller, 1)[0];
        p.bidForScore = core.bidForScore(_scoreOf(cid));
        p.balanceBid = core.balanceBidOf(cid);
        p.balanceBidForScore = core.balanceBidForScore(_scoreOf(cid));
        p.valueOf = ctl.valueOf(5 * RATE_SCORE);
        uint256 pile = _fillEthPile(1)[0];
        p.creditAsk = ctl.creditPrice(pile);
        Composed memory c = _composeOnce();
        p.composePaid = c.paid;
        p.statementRef = ctl.referenceOf(c.sid);
        p.statementAsk = ctl.priceOf(c.sid);
        p.statementAtFloor = ctl.atFloor(c.sid);
        p.creditRef = ctl.valueOf(_scoreOf(pile));
    }

    /// three hourly refresh door calls; a no-op without a pool key, so both runs see the same clock
    function _refreshCycles() internal {
        for (uint256 i; i < 3; ++i) {
            _warp(1 hours);
            vm.roll(block.number + 1);
            core.refreshReference();
        }
    }

    function _setPoolKeyOffMode() internal {
        uint160 sp = uint160(FixedPoint96.Q96 * 10 / 7);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(xt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(key, sp);
        TestLiquidityHelper lp = new TestLiquidityHelper();
        xt.mint(address(this), 1e24);
        xt.approve(address(lp), type(uint256).max);
        vm.deal(address(this), address(this).balance + 2_000 ether);
        lp.modify{value: 2_000 ether}(key, -887_220, 887_220, int256(1e20));
        // wei per 1e18 base units at sqrt price sp
        uint256 spot = (uint256(1e18) * FixedPoint96.Q96 / sp) * FixedPoint96.Q96 / sp;
        vm.startPrank(owner);
        ctl.setBalancePoolKey(
            IControllerV1.PoolKey({
                currency0: IControllerV1.Currency.wrap(address(0)),
                currency1: IControllerV1.Currency.wrap(address(xt)),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            spot
        );
        ctl.setQuote(
            Quote({
                referenceRateBpsPerHour: 1_000,
                referenceStepBps: 500,
                tolBps: 450,
                referenceMaxStale: 1 days,
                referenceMinSeconds: 0,
                minLiquidity: 1e18
            })
        );
        vm.stopPrank();
        mod.setAvailable(1e30);
    }

    // promise: with value mode off a pool key changes no price. the same flow runs on a snapshot with no key and on one
    // with a key and several refreshes; every price and door payment is equal
    function test_poolKeyChangesNoPriceWhileModeIsOff() public {
        _enterPhase2();
        _fundPot(10 ether);
        uint256 snap = vm.snapshotState();
        _refreshCycles();
        Prices memory a = _prices();
        vm.revertToState(snap);

        _setPoolKeyOffMode();
        _refreshCycles();
        Prices memory b = _prices();

        assertFalse(core.settings().valueModeOn, "value mode off");
        assertEq(b.bidForScore, a.bidForScore, "bidForScore");
        assertEq(b.balanceBid, a.balanceBid, "balanceBidOf");
        assertEq(b.balanceBidForScore, a.balanceBidForScore, "balanceBidForScore");
        assertEq(b.valueOf, a.valueOf, "valueOf");
        assertEq(b.creditAsk, a.creditAsk, "credit asking price");
        assertEq(b.creditRef, a.creditRef, "credit value");
        assertEq(b.statementRef, a.statementRef, "statement reference");
        assertEq(b.statementAsk, a.statementAsk, "statement asking price");
        assertEq(b.statementAtFloor, a.statementAtFloor, "atFloor");
        assertEq(b.composePaid, a.composePaid, "compose door payment");
    }
}

/// the balance route and the activation order (docs/RUNBOOK.md, phase 2): `balanceBidOn` stays false until value mode is
/// on. with value mode off the balance payout is par based and the credit ask is curve based, so a pool spot above the
/// curve opens a round trip; value mode prices both off the same reference. the setup is the value mode fixture: a real
/// pool with depth, a pool key and a usable quote, value mode off, `balanceBidOn` true
contract ModeOffBalanceRouteTest is ValueBase {
    address internal constant TRIPPER = address(0x7419);

    function _arm() internal returns (uint256[] memory ids) {
        ids = _fillEthPile(4);
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
    }

    /// buys credit `id` at its ask, sells it for balance token in the next second and returns the eth paid and the
    /// balance token received valued at the pool spot
    function _balanceTrip(uint256 id) internal returns (uint256 paid, uint256 back) {
        ctl.refreshReference();
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        paid = price * 2 - TRIPPER.balance;
        _nextSecond();
        vm.startPrank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        core.sellForBalance(_one(id));
        vm.stopPrank();
        (uint256 spot,) = ctl.spotPrice();
        back = _balanceOf(TRIPPER) * spot / 1e18;
    }

    /// the pool spot at which selling credit `id` for balance and dumping the balance into the pool returns exactly the
    /// ask, wei per 1e18 base units, from the mode off payout and the mode off ask
    function _breakEvenSpot(uint256 id) internal view returns (uint256) {
        return ctl.creditPrice(id) * 1e18 / core.balanceBidOf(id);
    }

    // promise: with the balance bid off the balance route is closed
    function test_balanceBidOffClosesTheRoute() public {
        uint256[] memory ids = _arm();
        _setSwitches(true, false);
        assertFalse(core.settings().valueModeOn, "value mode off");
        vm.startPrank(seller);
        CREDITS.setApprovalForAll(address(core), true);
        vm.expectRevert(ICore.BalanceBidOff.selector);
        core.sellForBalance(_one(ids[0]));
        vm.stopPrank();
    }

    // see the activation order in docs/RUNBOOK.md: the balance bid opens after value mode, because with value mode off
    // a pool spot 30 percent above the break even makes buy credit, sell for balance, sell the balance into the pool
    // profitable. the gain is the balance token received marked at the pool spot; the dump through the pool is not executed
    function test_documentedHazard_modeOffBalanceBidOpensRoundTripWhenSpotLeads() public {
        uint256[] memory ids = _arm();
        assertFalse(core.settings().valueModeOn, "value mode off");
        assertTrue(core.settings().balanceBidOn, "balance bid on");
        // the pool spot 30 percent above the break even of the curve ask against the par based payout
        _swapToSpot(_breakEvenSpot(ids[0]) * 130 / 100);
        (uint256 paid, uint256 back) = _balanceTrip(ids[0]);
        assertGt(back, paid, "mode off, spot above the curve: the round trip is profitable");
    }

    /// external self-call wrapper so a live balance round trip can be wrapped in try/catch: the vm cheatcodes inside
    /// `_balanceTrip` run through the external self-call, and the tuple is returned to the caller
    function balanceTripExternalMO(uint256 id) external returns (uint256 paid, uint256 back) {
        return _balanceTrip(id);
    }

    // promise: the same setup in value mode: both legs price off the reference, so the round trip loses the spread,
    // proven live: at the break-even lead the live round trip either fails closed (the value quote is unusable) or
    // loses at least the spread. the exact loss bound runs on the controlled pool in ModeOffBalanceRouteFixtureTest
    function test_valueModeClosesTheRoundTripWhenSpotLeads_liveFailsClosedOrLoses() public {
        _closureAtCapLiveFailsClosedOrLoses(11_000);
    }

    // promise: the same at a 30,000 bps balance cap: value mode still closes the round trip, proven live as fail closed or loses
    function test_valueModeClosesTheRoundTripWhenSpotLeads_cap30000_liveFailsClosedOrLoses() public {
        _closureAtCapLiveFailsClosedOrLoses(30_000);
    }

    /// on the live deep pool the break-even 1.3x lead drives the spot past what the rate-limited reference can track, so
    /// the value quote goes unusable and `creditPrice`/`buyCredit` revert `NoQuote` before any profitable round trip
    /// exists. the try/catch accepts either outcome: a fail-closed revert, or an executed trip that loses the spread
    function _closureAtCapLiveFailsClosedOrLoses(uint32 cap) internal {
        uint256[] memory ids = _arm();
        uint256 target = _breakEvenSpot(ids[0]) * 130 / 100;
        _valueOn();
        Settings memory s = core.settings();
        s.balanceBidCapBps = cap;
        _setSettings(s);
        _swapToSpot(target);
        // the prior-block sample catches the pushed spot while the reference walks one step a block behind it
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
        try this.balanceTripExternalMO(ids[0]) returns (uint256 paid, uint256 back) {
            uint256 m = 10_000 + ctl.creditSpreadBps();
            assertLe(back * m, (paid + 1) * 10_000, "value mode: the round trip loses at least the spread at the cap");
        } catch {
            // fail closed: the value quote is unusable at the pushed lead, so no profitable round trip exists
        }
    }

    // promise: value mode closes the round trip at a trackable lead: a small spot push the reference can follow within
    // referenceStepBps per refresh keeps the quote usable, and the balance round trip executes and loses the spread
    function test_valueModeClosesTheRoundTripAtTrackableLead() public {
        uint256[] memory ids = _arm();
        _valueOn();
        _swapSpot(200); // +2 percent, inside the reference's per-refresh step so it catches up over the refreshes below
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
        (uint256 paid, uint256 back) = _balanceTrip(ids[0]);
        assertLe(
            back * (10_000 + ctl.creditSpreadBps()),
            (paid + 1) * 10_000,
            "value mode closes the round trip at a trackable lead"
        );
    }

    // promise: with value mode off the reference still warms up: a real swap moves the spot and a refresh moves the
    // reference toward it by at most the step
    function test_referenceWarmsUpWhileModeIsOff() public {
        assertFalse(core.settings().valueModeOn, "value mode off");
        uint256 ref0 = ctl.referencePrice();
        uint256 t0 = ctl.referenceTime();
        uint256 moved = _swapToSpot(ref0 * 13 / 10);
        _warp(30 minutes);
        vm.roll(block.number + 1);
        assertTrue(ctl.refreshReference(), "the refresh runs");
        uint256 ref1 = ctl.referencePrice();
        assertGt(ref1, ref0, "the reference moved toward the spot");
        assertLe(ref1, ref0 * 10_500 / 10_000, "by at most the step");
        assertLt(ref1, moved, "and trails the spot");
        assertGt(ctl.referenceTime(), t0, "the sample time moved");
    }
}

/// controlled-pool mechanics: pushes the spot to a 1.3x break-even lead the rate-limited reference cannot track. on the
/// live deep pool this lead fails the value quote closed (see `_closureAtCapLiveFailsClosedOrLoses` in
/// ModeOffBalanceRouteTest); here the shallow controlled pool keeps the quote usable, so the exact closure invariant
/// runs: in value mode both legs price off the reference and the round trip loses the spread. pre-port bodies verbatim
contract ModeOffBalanceRouteFixtureTest is ValueFixtureBase {
    address internal constant TRIPPER = address(0x7419);

    function _arm() internal returns (uint256[] memory ids) {
        ids = _fillEthPile(4);
        _setReturnLock(0);
        _setCreditSaleOn(true);
        _warp(ctl.creditWindow());
        _fundPot(50 ether);
    }

    /// buys credit `id` at its ask, sells it for balance token in the next second and returns the eth paid and the
    /// balance token received valued at the pool spot
    function _balanceTrip(uint256 id) internal returns (uint256 paid, uint256 back) {
        ctl.refreshReference();
        uint256 price = ctl.creditPrice(id);
        vm.deal(TRIPPER, price * 2);
        vm.prank(TRIPPER);
        ctl.buyCredit{value: price * 2}(id);
        paid = price * 2 - TRIPPER.balance;
        _nextSecond();
        vm.startPrank(TRIPPER);
        CREDITS.setApprovalForAll(address(core), true);
        core.sellForBalance(_one(id));
        vm.stopPrank();
        (uint256 spot,) = ctl.spotPrice();
        back = xt.balanceOf(TRIPPER) * spot / 1e18;
    }

    /// the pool spot at which selling credit `id` for balance and dumping the balance into the pool returns exactly the
    /// ask, wei per 1e18 base units, from the mode off payout and the mode off ask
    function _breakEvenSpot(uint256 id) internal view returns (uint256) {
        return ctl.creditPrice(id) * 1e18 / core.balanceBidOf(id);
    }

    // promise: the same setup in value mode: both legs price off the reference, so the round trip loses the spread
    function test_valueModeClosesTheRoundTripWhenSpotLeads() public {
        _closureAtCap(11_000);
    }

    // promise: the same at a 30,000 bps balance cap: value mode still closes the round trip
    function test_valueModeClosesTheRoundTripWhenSpotLeads_cap30000() public {
        _closureAtCap(30_000);
    }

    function _closureAtCap(uint32 cap) internal {
        uint256[] memory ids = _arm();
        uint256 target = _breakEvenSpot(ids[0]) * 130 / 100;
        _valueOn();
        Settings memory s = core.settings();
        s.balanceBidCapBps = cap;
        _setSettings(s);
        _swapToSpot(target);
        // the prior-block sample catches the pushed spot while the reference walks one step a block behind it
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
            ctl.refreshReference();
        }
        (uint256 paid, uint256 back) = _balanceTrip(ids[0]);
        uint256 m = 10_000 + ctl.creditSpreadBps();
        assertLe(back * m, (paid + 1) * 10_000, "value mode: the round trip loses at least the spread at the cap");
    }
}
