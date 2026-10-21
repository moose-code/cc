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
import {LiveFixture} from "./utils/LiveFixture.sol";


/// promise: SPEC 4 with value mode off, bid, drop, ceiling, credit sale price and statement decay match formulas using
/// the current settings and getters. these checks do not compare against a pinned historical implementation. value mode
/// is off on the live system. the climb and ceiling cases overlap BidRule; the sale cases overlap CreditSale and Sale.
/// ported to the live Core/controller/pile: the settings are read live (they differ from the launch config, so the
/// launch-value sanity assertions below are rewritten to the live values), and the fills move real strategy credits at
/// their real scores instead of a mocked unit score
contract ModeOffPricingRulesTest is LiveFixture {
    uint256 internal constant BPS = 10_000;

    /// the expected eth price state after one fill of a credit of score `score` with the price state `price` at the
    /// fill: the contract drop `price * (10_000 * RATE_SCORE - dropPer100PointsBps * score) / (10_000 * RATE_SCORE)`,
    /// never below the minute floor. the live `dropFloorBps` is 1, so the floor is negligible and never binds for a
    /// real score; it is kept here to mirror `_drop` exactly
    function _droppedRate(uint256 price, uint256 score) internal view returns (uint256) {
        Settings memory s = core.settings();
        uint256 denom = BPS * RATE_SCORE;
        uint256 fallNum = uint256(s.dropPer100PointsBps) * score;
        uint256 dropped = fallNum >= denom ? 0 : price * (denom - fallNum) / denom;
        // first fill of a bucket restates the minute floor to `price`; `_anchor` reads the live minute start otherwise
        (, uint256 minuteStart, uint256 minuteBucket) = _anchor();
        uint256 bucket = block.timestamp / s.bucketSeconds;
        uint256 start = (bucket != minuteBucket || minuteStart == 0 || price < minuteStart * s.dropFloorBps / BPS)
            ? price
            : minuteStart;
        uint256 floor = start * s.dropFloorBps / BPS;
        if (dropped < floor) dropped = floor;
        if (dropped < 1) dropped = 1;
        return dropped;
    }

    /// composes a page from the live pile. the live credit sale is on and the live pile holds credits still inside their
    /// window, so `compose` refuses them until the window passes; warp past it first (the sale-on window rule). the live
    /// pile already holds a full page, so no fresh fill is needed. returns the new statement id and the keeper payment
    function _composeLive() internal returns (uint256 sid, uint256 paid) {
        if (core.pileSize() < 80) {
            _fundPot(50 ether);
            _fillEthPile(80 - core.pileSize());
        }
        _warp(ctl.creditWindow() + 1);
        vm.fee(composeBasefee);
        sid = STATEMENTS.supply() + 1;
        uint256 before = keeper.balance;
        vm.prank(keeper);
        core.compose();
        paid = keeper.balance - before;
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

    // a fill drops the price state by dropPer100PointsBps per 100 points scaled by the credit's score: the new state is
    // `rate * (10_000 * RATE_SCORE - dropPer100PointsBps * score) / (10_000 * RATE_SCORE)`. a real strategy credit is
    // used at its real score instead of a mocked unit score (the owner rule: never mock the live CreditScore)
    function test_dropIsTheLaunchDrop() public {
        _fundPot(10 ether);
        uint256 id = _credits(seller, 1)[0];
        uint256 score = _scoreOf(id);
        uint256 r0 = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
        uint256 drop = core.settings().dropPer100PointsBps;
        assertEq(
            core.rateAtCheckpoint(),
            _droppedRate(r0, score),
            "the drop is dropPer100PointsBps per 100 points, score scaled"
        );
        assertEq(drop, 29, "the live drop (launch config was 115)");
    }

    // a pile credit at acquisition is asked at creditStartBps (1.5x) of its floor; the floor is recomputed from the
    // contract's views at the same instant, so the comparison does not drift with the climbing floor rate
    function test_creditSaleStartIsOverTheFloor() public {
        _setCreditSaleOn(true);
        // the pile fill needs pot room above the live reserve for a real, possibly high score credit
        _fundPot(10 ether);
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
        // the decayHours curve is ControllerV1's statement pricing; ControllerV2 prices a held Statement at its
        // multiplier of the reference after the redeem delay (test/ControllerV2.t.sol), so the curve does not exist in B
        if (_liveStageB()) return;
        (uint256 sid,) = _composeLive();
        // the reference moves with the climbing floor rate, so read it fresh at each age
        assertEq(
            ctl.priceOf(sid), ctl.referenceOf(sid) * ctl.startBps() / BPS, "the start ask is startBps of the reference"
        );
        _warp(uint256(ctl.decayHours()) * 1 hours + 1);
        assertEq(
            ctl.priceOf(sid),
            ctl.referenceOf(sid) * core.settings().saleFloorBps / BPS,
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
        _fundPot(10 ether);
        uint256 pile = _fillEthPile(1)[0];
        p.creditAsk = ctl.creditPrice(pile);
        (uint256 sid, uint256 paid) = _composeLive();
        p.composePaid = paid;
        p.statementRef = ctl.referenceOf(sid);
        p.statementAsk = ctl.priceOf(sid);
        p.statementAtFloor = ctl.atFloor(sid);
        p.creditRef = ctl.valueOf(_scoreOf(pile));
    }

    /// three hourly refresh door calls; so both runs see the same clock
    function _refreshCycles() internal {
        for (uint256 i; i < 3; ++i) {
            _warp(1 hours);
            vm.roll(block.number + 1);
            core.refreshReference();
        }
    }

    /// points the controller at the live eth / BALANCE pool, the owner's stage C action. with value mode off this must
    /// change no price; it replaces the old mock pool (the mock xt/mod/lp balance API is gone under LiveFixture)
    function _setPoolKeyOffMode() internal {
        _setLiveBalancePool();
    }

    // promise: with value mode off a pool key changes no price. the same flow runs on a snapshot with no key and on one
    // with the live balance pool key and several refreshes; every price and door payment is equal
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

    // live counterpart to ModeOffClimbControlledTest.test_climbCeilingAndLoosening. at the live climb rate
    // (climbPerMinBps 100, 1 percent a minute) the roughly 10 percent climb to the 110 percent ceiling takes about a
    // full idle step, so the launch test's "holds at the ceiling before the first idle step" window does not exist on
    // live. this exercises the same ceiling and idle loosening path with the live settings: once the climb saturates at
    // the ceiling, the ceiling rises by exactly the idle loosening ratio over a further idle step. a pot of one page
    // keeps the climb multiplier at 1x, so the loosening is the base idleLoosenBps
    function test_ceilingLoosensOverIdleSteps() public {
        Settings memory s = core.settings();
        // fill through the pile: `_fillEthPile` restates the price state to the live opening rate (`RATE_START`), so the
        // ceiling (110 percent of that low anchor) stays well under `rateCap` and the idle loosening is observable; at
        // the live rateCap the ceiling at the live anchor would clamp and never rise. one page of pot keeps the
        // multiplier at 1x, so the loosening is the base idleLoosenBps
        _fundPot(1 ether);
        _fillEthPile(1);
        assertEq(core.climbMultiplier(), BPS, "a one page pot keeps the multiplier at 1x");
        // saturate the climb at the ceiling (well past the gap at 1 percent a minute), then read it one idle step apart
        uint256 idle1 = 40 minutes;
        _warp(idle1);
        uint256 rate1 = core.ethRate();
        _warp(uint256(s.idleStepSeconds));
        uint256 idle2 = idle1 + s.idleStepSeconds;
        uint256 rate2 = core.ethRate();
        uint256 loos1 = BPS + uint256(s.idleLoosenBps) * (idle1 / s.idleStepSeconds);
        uint256 loos2 = BPS + uint256(s.idleLoosenBps) * (idle2 / s.idleStepSeconds);
        assertGt(rate2, rate1, "the ceiling loosens over another idle step");
        assertApproxEqAbs(rate2 * loos1, rate1 * loos2, 1e6, "the saturated ceiling scales by the idle loosening");
        assertEq(s.ceilBps, 11_000, "ceiling 110 percent");
        assertEq(s.climbPerMinBps, 100, "the live climb 1 percent a minute (launch config was 200)");
        assertEq(s.idleLoosenBps, 600, "loosen 6 percent per idle step");
    }
}

/// controlled-input counterpart: the launch climb config (climbPerMinBps 200, 2 percent a minute) over a clean launch
/// anchor is an input the live system cannot reproduce (live climbPerMinBps is 100 and the live anchor carries history),
/// so this exact-timing case stays on the fresh `Fixture` with a mocked unit score. the live counterpart that exercises
/// the same ceiling and idle loosening code path against live settings is
/// ModeOffPricingRulesTest.test_ceilingLoosensOverIdleSteps
contract ModeOffClimbControlledTest is Fixture {
    uint256 internal constant BPS = 10_000;

    function _recoveryEqualsClimb() internal {
        Settings memory s = core.settings();
        s.recoveryClimbPerMinBps = s.climbPerMinBps;
        _setSettings(s);
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
