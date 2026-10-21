// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RATE_SCORE} from "../src/interfaces/Interfaces.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BidModel} from "./utils/BidModel.sol";
import {Fixture} from "./utils/Fixture.sol";
import {LiveFixture} from "./utils/LiveFixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet, ICreditStrategy} from "../src/interfaces/Interfaces.sol";
import {ListingTarget} from "./attackers/ListingTarget.sol";

/// @notice the credit bid rule on the real stack: the drop per credit with its minute floor, the compounded climb per
/// minute, the ceiling at a share of the last rate paid with its idle loosening, the funded clamp (the price of one credit
/// that the pot affords), the settings bounds, and the recovery after a gap in the market price. exact numbers at the launch
/// settings, hand arithmetic throughout.
///
/// these mechanics isolate the rate curve by forcing score == RATE_SCORE (ratio 1) with `_unitScore`, which is
/// unreachable with real credits, and they assert exact numbers that only hold at the launch settings. so this contract
/// stays on the fresh-deploy `Fixture`. its live counterpart, `BidRuleLiveTest` below, runs the same drop and climb code
/// paths against the live Core with a real credit and the live settings: the scaled drop and the anchor in
/// `test_liveFillDropsTheScaledDropAndSetsTheAnchor`, the climb and the rate cap in
/// `test_liveClimbRaisesTheBidAndHoldsUnderTheRateCap`
contract BidRuleTest is Fixture {
    /// the live Core at pin block 26242107, read whole so every bid-rule field is the production value
    address internal constant LIVE_CORE = 0xcdb1889ae12074d750CD9B8531B692015465e0dD;

    /// Addendum 4: the bid rule is proven against the FULL live Core settings struct read at the pin, not the launch
    /// defaults. reading the live Core binds every field to its production value: besides the drop 29, climb 100 and
    /// recovery climb 100 and rateCap 1.71e16, this also brings reserveWei 1e17, buyToArtistBps 250 and
    /// feeToRedeemBurnBps 1000. every expected number is recomputed from `core.settings()` and `core.reserve()`: the pot
    /// clamp and climb limit read the eth bid room `(pot - reserve) * 10_000 / (10_000 + buyToArtistBps)` (`_room`), and
    /// the booked pot share is net of the redeem burn. the suite reads the live settings, so it must run on a fork at or
    /// near the pin (after stage B buyToArtistBps is 300, which the lead's stage B run covers; this handles today's 250)
    function _settings() internal view override returns (Settings memory s) {
        s = ICore(payable(LIVE_CORE)).settings();
    }

    using stdStorage for StdStorage;

    uint256 internal constant START = OPEN_RATE;

    /// @dev the eth bid room the live Core affords from `pot`: the pot less the live reserve, over 1 + buyToArtistBps /
    /// 10_000 (so a shown bid is payable with its artist royalty on top). mirrors `CoreLib._roomAt`, the value the read
    /// clamps to. for the test pot magnitudes the plain mul floors the same as the contract's mulDiv
    function _room(uint256 pot) internal view returns (uint256) {
        return (pot - core.reserve()) * 10_000 / (10_000 + core.settings().buyToArtistBps);
    }

    /// @dev the price state after one 100-point credit bought at state `r`, from the live settings (ratio 1, so the fall
    /// is the full `dropPer100PointsBps`). recomputed through the shared `BidModel`, never a launch constant
    function _unitDrop(uint256 r) internal view returns (uint256) {
        return BidModel.dropOnce(core.settings(), r, r, RATE_SCORE);
    }

    /// @dev `base` grown by `mins` minutes of the live per-minute climb, through the same lnWad/expWad path as
    /// CoreLib, so the expected read matches the contract within rounding. recomputed from the live climbPerMinBps
    function _climbOver(uint256 base, uint256 mins) internal view returns (uint256) {
        int256 lnRate = FixedPointMathLib.lnWad(int256(1e18 + uint256(core.settings().climbPerMinBps) * 1e14));
        return FixedPointMathLib.mulWad(base, uint256(FixedPointMathLib.expWad(lnRate * int256(mins))));
    }

    /// @dev books `eth` into the buying pot through the real `skim` door
    function _potTo(uint256 eth) internal {
        uint256 have = core.ethPot();
        if (have >= eth) return;
        _addToPot((eth - have));
    }

    function _with(function(Settings memory) pure f) internal {
        Settings memory s = core.settings();
        f(s);
        // these hand arithmetic tests predate the recovery climb (decision 74) and assert a single rate climb; match the
        // recovery rate to the climb rate so a fill does not switch the climb to the faster recovery rate. the recovery
        // itself is covered in test/Recovery.t.sol
        s.recoveryClimbPerMinBps = s.climbPerMinBps;
        _setSettings(s);
    }

    /// sells one credit with its score mocked to 100 points, so the eth bid pays the full per-100-point rate and
    /// the drop is exactly `dropPer100PointsBps`. the scaled bid and scaled drop at other scores are in
    /// test/PerPointExact.t.sol
    function _sellOne() internal returns (uint256 price) {
        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        price = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    // ------------------------------------------------------------------ drop

    // promise: SPEC 1 the bid rule: a fill drops the price state by dropPer100PointsBps
    function test_oneFillDropsTheLaunchDrop() public {
        _potTo(10 ether);
        uint256 r0 = core.ethRate();
        assertEq(r0, START);
        uint256 price = _sellOne();
        assertEq(price, r0, "the rate before the fill");
        // a 100 point credit drops the rate by dropPer100PointsBps (29 bps live, pin 26242107): (10_000 - 29) / 10_000
        assertEq(core.rateAtCheckpoint(), _unitDrop(r0), "the live drop below the rate paid");
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, r0, "the rate paid is the anchor");
        assertEq(start, r0, "and the start of the minute");
        assertEq(bucket, block.timestamp / 60);
        assertEq(core.lastFillTime(), block.timestamp);
    }

    // promise: rounding a tiny positive ETH price down on a fill cannot make the price state permanently zero
    function test_tinyRateRemainsPositiveAcrossFills() public {
        Settings memory cfg = core.settings();
        cfg.dropPer100PointsBps = 9_999;
        cfg.dropFloorBps = 1;
        _setSettings(cfg);
        assertEq(BidModel.dropOnce(cfg, 1, 1, RATE_SCORE), 1, "the invariant model keeps the same one-wei floor");
        _potTo(1 ether);
        vm.prank(owner);
        core.setRate(2);
        uint256[] memory ids = _credits(seller, 2);
        for (uint256 i; i < ids.length; ++i) {
            _unitScore(ids[i]);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            assertEq(core.rateAtCheckpoint(), 1, "the stored state stays positive after each rounded drop");
            assertGt(core.ethPrice(), 0, "the next read can recover from the positive state");
        }
    }

    // promise: SPEC 1 the minute floor dropFloorBps bounds the drop inside a minute
    /// with a 5 percent drop and a 50 percent floor the floor is reached on the 14th fill in one minute (0.95^13 is
    /// above 0.5, 0.95^14 is below it, so the 14th fill clamps to the floor). set here, since launch runs no practical
    /// minute floor (dropFloorBps 1, decision 146)
    function test_dropReachesTheMinuteFloor() public {
        Settings memory cfg = core.settings();
        cfg.dropPer100PointsBps = 500;
        cfg.dropFloorBps = 5_000;
        _setSettings(cfg);
        _potTo(40 ether);
        uint256 r0 = core.ethRate();
        uint256[] memory ids = _credits(seller, 14);
        for (uint256 i; i < ids.length; ++i) {
            // a 100 point credit drops the rate by the full dropPer100PointsBps (5 percent here)
            _unitScore(ids[i]);
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            if (i == 12) assertGt(core.rateAtCheckpoint(), r0 * 5_000 / 10_000, "13 fills are above the floor");
        }
        assertEq(core.rateAtCheckpoint(), r0 * 5_000 / 10_000, "14 fills sit on the floor");
    }

    // ------------------------------------------------------------------ climb

    // promise: inv 19 the read is at most the price state and follows the pot
    /// the read does not fall as the pot grows and never exceeds the price state
    function test_readIsMonotoneInThePot() public {
        // the bid room is the pot less the live reserve over 1 + buyToArtistBps / 10_000, so the sweep rides above the
        // reserve and the room the pot affords is `_room(pot)`
        uint256 res = core.reserve();
        uint256 last;
        for (uint256 i; i <= 60; ++i) {
            _potTo(res + i * 0.05e15);
            uint256 read = core.ethRate();
            assertGe(read, last, "the read does not fall as the pot grows");
            assertLe(read, core.rateAtCheckpoint(), "the read is at most the price state");
            last = read;
        }
        assertEq(last, START, "a pot whose room exceeds the price state reads the price state");
        // the smallest pot whose room funds the full price state, and one wei of pot under it: the room falls below
        uint256 fundPot = res + uint256(START) * (10_000 + core.settings().buyToArtistBps) / 10_000;
        stdstore.target(address(core)).sig("ethPot()").checked_write(fundPot - 1);
        vm.deal(address(core), fundPot - 1);
        uint256 room = _room(core.ethPot());
        assertLt(room, START, "one wei under the funding pot the room is below the price state");
        assertEq(core.ethRate(), room, "the read is the room the pot affords");
    }

    // ------------------------------------------------------------------ ceiling

    // promise: SPEC 1 the bid rule at launch: ceilBps 11_000
    /// the rate stops at 110 percent of the anchor grown by the loosening (the minimum setting, 1 basis point per 10
    /// idle minutes, scaled 4x by the 20 eth pot): the anchor is the rate paid at the last fill
    function test_ceilingHoldsAt110PercentOfTheAnchor() public {
        _with(_minLoosening);
        _potTo(20 ether);
        _warp(1 hours);
        uint256 r0 = core.ethRate();
        assertGt(r0, START, "the climb took the rate above the opening rate");
        _sellOne();
        (uint256 anchor,,) = _anchor();
        assertEq(anchor, r0);
        _warp(3 hours);
        // the 20 eth pot buys more than four pages, so the loosening runs at the 4x cap: 18 intervals of 1 bp times 4
        assertEq(
            core.ethRate(), r0 * (10_000 + 72) * 11_000 / 1e8, "110 percent of the rate paid, 18 intervals of 4 bp"
        );
        _warp(30 days);
        assertEq(
            core.ethRate(), r0 * (10_000 + 17_352) * 11_000 / 1e8, "4,338 intervals times 4 after 30 days and 3 hours"
        );
        assertEq(core.rateAtCheckpoint(), _unitDrop(r0), "stored until the next checkpoint");
    }

    function _minLoosening(Settings memory s) internal pure {
        s.idleLoosenBps = 1;
    }

    /// the loosening the mechanics tests below are written against: 2 percent per 10 idle minutes
    function _twoPercentLoosening(Settings memory s) internal pure {
        s.idleLoosenBps = 200;
    }

    // promise: SPEC 1 the bid rule at launch: idleLoosenBps 600
    /// the launch setting at a 1x pot: the anchor grows 6 percent per full 10 idle minutes (decision 128)
    function test_anchorLoosensSixPercentPerTenIdleMinutesAtLaunch() public {
        assertEq(core.settings().idleLoosenBps, 600);
        _with(_fastClimbOnly);
        // a pot under one page (above the live reserve so the fill passes) keeps the multiplier at 1x, so the loosening
        // is the base 6 percent per 10 minutes
        _potTo(core.reserve() + 0.1 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(9 minutes + 59);
        assertEq(core.settings().ceilBps, 11_000);
        assertEq(core.ethRate(), anchor * 11_000 / 10_000, "no loosening before 10 idle minutes");
        _warp(1);
        assertEq(core.ethRate(), anchor * 10_600 * 11_000 / 1e8, "6 percent after 10 minutes");
        _warp(10 minutes);
        assertEq(core.ethRate(), anchor * 11_200 * 11_000 / 1e8, "12 percent after 20 minutes");
    }

    function _fastClimbOnly(Settings memory s) internal pure {
        s.climbPerMinBps = 1_000;
    }

    function _fastClimb(Settings memory s) internal pure {
        s.climbPerMinBps = 1_000;
        s.idleLoosenBps = 200;
    }

    // promise: SPEC 1 a fill resets the idle loosening
    /// a fill resets the idle clock: the anchor is the rate paid then
    function test_aFillResetsTheLoosening() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _sellOne();
        _warp(40 minutes);
        uint256 r = core.ethRate();
        (uint256 anchorBefore,,) = _anchor();
        // idleLoosen 200 scaled 4x by the 20 eth pot: 8 percent per 10 minutes, 32 percent over 40 minutes
        assertEq(r, anchorBefore * 13_200 * 11_000 / 1e8, "loosened 32 percent");
        _sellOne();
        (uint256 anchor,,) = _anchor();
        assertEq(anchor, r, "the rate paid is the new anchor");
        _warp(5 minutes);
        assertEq(core.ethRate(), r * 11_000 / 10_000, "idle clock restarted, no loosening yet");
    }

    // ------------------------------------------------------------------ clamp

    // promise: inv 19 the read is the price state or the pot
    /// the rate never exceeds the price of one credit that the pot affords: the pot
    function test_clampHoldsAtThePotWhenItAffordsLessThanOneCredit() public {
        _with(_openCeiling);
        // the clamp is the one-credit price the pot affords: the room `_room(pot)` (pot less reserve over the royalty)
        uint256 res = core.reserve();
        _potTo(res + START / 2);
        _warp(3 days);
        uint256 clamp = _room(core.ethPot());
        assertEq(core.ethRate(), clamp, "held at the clamp");
        _warp(30 days);
        assertEq(core.ethRate(), clamp);
        // more fees lift the clamp, the climb resumes from the stored rate
        _potTo(res + START * 3 / 4);
        uint256 clamp2 = _room(core.ethPot());
        assertGt(clamp2, clamp);
        _warp(1 days);
        assertEq(core.ethRate(), clamp2);
    }

    function _openCeiling(Settings memory s) internal pure {
        s.ceilBps = 30_000;
        s.climbPerMinBps = 1_000;
    }

    // ------------------------------------------------------------------ bounds

    function _expectBad(Settings memory s, bytes32 field) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICore.BadSetting.selector, field));
        core.setSettings(s);
    }

    // promise: INTEGRATION BadSetting on the bid rule settings
    function test_boundsRevertOnEveryOutOfRangeValue() public {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPer100PointsBps = 0;
        _expectBad(s, "dropPer100PointsBps");
        s = Mainnet.defaultSettings();
        s.dropPer100PointsBps = 10_001;
        _expectBad(s, "dropPer100PointsBps");
        s = Mainnet.defaultSettings();
        s.dropFloorBps = 10_001;
        _expectBad(s, "dropFloorBps");
        s = Mainnet.defaultSettings();
        s.climbPerMinBps = 0;
        _expectBad(s, "climbPerMinBps");
        s = Mainnet.defaultSettings();
        s.ceilBps = 9_999;
        _expectBad(s, "ceilBps");
        s = Mainnet.defaultSettings();
        s.idleLoosenBps = 0;
        _expectBad(s, "idleLoosenBps");
    }

    // ------------------------------------------------------------------ hard bounds

    // promise: SPEC 1 an empty pot never raises the price (decision 44)
    /// a pot with under one credit of room for 10 hours does not raise the price state: the climb stops at the clamp, so a
    /// refill resumes from the price before the starvation
    function test_starvedPotDoesNotRaiseThePriceState() public {
        _potTo(20 ether);
        _sellOne();
        uint256 price = core.rateAtCheckpoint();
        // drain the pot to under one credit of room (the live reserve plus 1e15), then book 1 wei so a checkpoint runs
        // at the small pot. the room the read clamps to is the pot less the reserve
        uint256 res = core.reserve();
        stdstore.target(address(core)).sig("ethPot()").checked_write(res + 1e15);
        vm.deal(address(core), res + 1e15 + 1);
        core.book();
        assertEq(core.ethPot(), res + 1e15 + 1);
        assertEq(core.rateAtCheckpoint(), price, "the price state is not lowered by the small pot");
        _warp(10 hours);
        assertEq(core.ethRate(), _room(core.ethPot()), "the read is the clamp of the small pot");
        _addToPot(1);
        assertEq(core.rateAtCheckpoint(), price, "and a starved pot does not raise the price state");
        _potTo(20 ether);
        assertEq(core.rateAtCheckpoint(), price, "the checkpoint at the refill stores the price from before");
        assertEq(core.ethRate(), price, "the read after the refill is that price");
        _warp(10 minutes);
        // the climb is unscaled (climbPerMinBps 100 live, pin 26242107): 1.01 per minute over ten minutes
        assertApproxEqRel(core.ethRate(), _climbOver(price, 10), 1e9, "and it climbs from there");
    }

    // promise: pending fees do not age the ETH bid before they are booked into buying room
    function test_pendingFeesDoNotStartEmptyClock() public {
        _with(_openCeiling);
        assertEq(core.ethPot(), 0, "nothing booked at launch");
        assertEq(address(core).balance, 0, "fresh deploy holds no eth");
        vm.deal(address(core), 1 ether);
        vm.prank(owner);
        core.setRate(START);
        assertEq(core.ethRate(), START, "the opening rate before the climb");
        _warp(10 minutes);
        assertEq(core.ethPot(), 0, "fee income is still unbooked");
        assertEq(core.ethRate(), START, "pending income gives no elapsed climb");
        core.book();
        assertEq(core.ethRate(), START, "booking starts from the opening rate");
        _warp(10 minutes);
        assertGt(core.ethRate(), START, "the booked pot now funds the climb");
    }

    // promise: SPEC 1 decision 147: a payable door's own value is not pending income
    /// `fund` books the income above the pots, checkpoints, then adds `msg.value` to the pot. the checkpoint runs while
    /// `msg.value` is on the balance but not in a pot, and it reads a zero pending pot, so the stored price holds
    function test_payableDoorExcludesItsOwnValueFromPendingIncome() public {
        assertEq(core.ethPot(), 0, "nothing booked at launch");
        assertEq(address(core).balance, 0, "fresh deploy holds no eth");
        _warp(10 minutes);
        vm.deal(address(this), 1 ether);
        core.fund{value: 1 ether}();
        assertEq(core.ethPot(), 1 ether, "the whole value is the pot, none booked as fee income");
        assertEq(core.rateAtCheckpoint(), START, "fund's own value is not pending income, the climb held at the pot");
    }

    // promise: booking pending income starts the clock without crediting prior empty time
    function test_bookStartsClimbWithoutRetroactiveRise() public {
        _with(_openCeiling);
        vm.deal(address(core), 5 ether);
        vm.prank(owner);
        core.setRate(START);
        _warp(10 minutes);
        uint256 before = core.ethRate();
        assertEq(before, START, "pending income does not fund the clock");
        core.book();
        // the live feeToRedeemBurnBps (1000, pin 26242107) moves that share of the booked income to the redeem burn
        // pot, the rest to the buying pot
        uint256 feeBurn = core.settings().feeToRedeemBurnBps;
        uint256 toPot = 5 ether - 5 ether * feeBurn / 10_000;
        assertEq(core.ethPot(), toPot, "the booked income fills the pot net of the redeem burn share");
        assertEq(core.ethRate(), before, "book does not award the prior ten minutes");
        _warp(10 minutes);
        assertGt(core.ethRate(), before, "the climb continues from the booked pot");
    }

    // promise: the empty-pot clock starts only when booked room pays a 100-point bid plus royalty above reserve
    function test_booked100PointThresholdIncludesRoyaltyAndReserve() public {
        Settings memory s = core.settings();
        s.reserveWei = 0.1 ether;
        s.buyToArtistBps = 250;
        _setSettings(s);
        uint256 opening = 0.0049 ether;
        vm.prank(owner);
        core.setRate(opening);
        uint256 threshold = 0.1 ether + opening * 10_250 / 10_000;
        assertEq(threshold, 0.1050225 ether, "reserve plus the 100-point bid and 2.5 percent royalty");
        // the live book splits income: the pot keeps income - income * feeToRedeemBurnBps / 10_000 (= income - floor of
        // income/10 at the live 1000). booking `_bookTo(P)` lands the pot exactly at P despite that floor, so the
        // funding boundary is still exercised one wei of pot at a time
        uint256 burn = core.settings().feeToRedeemBurnBps;
        assertEq(burn, 1_000, "the live redeem burn share, pin 26242107");

        _warp(6 hours);
        core.book();
        assertEq(core.ethRate(), 0, "an empty book does not start the clock");
        uint256 below = _bookTo(threshold - 1);
        assertEq(core.ethPot(), threshold - 1, "the first book remains below the funding threshold");
        _warp(1 hours);
        assertEq(core.ethPrice(), opening, "the price state did not age below the threshold");

        // one wei more of income raises the pot one wei (the burn floor takes nothing from a single wei) to the threshold
        vm.deal(address(core), below + 1);
        core.book();
        assertEq(core.ethPot(), threshold, "one wei more exactly funds the 100-point bid");
        assertEq(core.ethRate(), opening, "the funded pot holds the opening rate");
        vm.deal(address(core), address(core).balance + 0.1 ether);
        core.book();
        _warp(10 minutes);
        assertGt(core.ethRate(), opening, "only funded time raises the bid");
    }

    /// @dev sets the Core balance so a single `book` lands `ethPot` exactly at `pot` under the live redeem burn split
    /// (`ethPot += income - income * feeToRedeemBurnBps / 10_000`, floored). returns the balance dealt. only valid from
    /// an empty pot. the split is 10 percent at the live 1000, so for income = 10a + b (b < 10) the pot gains 9a + b;
    /// choosing b = pot mod 9 and a = (pot - b) / 9 makes 9a + b == pot exactly
    function _bookTo(uint256 pot) internal returns (uint256 income) {
        uint256 b = pot % 9;
        uint256 a = (pot - b) / 9;
        income = 10 * a + b;
        vm.deal(address(core), income);
        core.book();
    }

    function _thresholdEdge(uint256 rate, uint16 artistBps) internal {
        Settings memory s = core.settings();
        s.reserveWei = 0.1 ether;
        s.rateCap = type(uint64).max;
        s.buyToArtistBps = artistBps;
        if (artistBps == 1_000) s.balanceDiscountBps = 1_100;
        _setSettings(s);
        vm.prank(owner);
        core.setRate(rate);
        uint256 threshold = uint256(s.reserveWei) + (rate * (10_000 + artistBps) + 9_999) / 10_000;

        vm.deal(address(core), threshold - 1);
        core.book();
        _warp(6 hours);
        assertEq(core.ethPrice(), rate, "one wei short remains paused after six hours");
        vm.deal(address(core), threshold);
        core.book();
        assertEq(core.ethPrice(), rate, "exact funding starts now, with no prior climb");
    }

    // promise: decision 176 the minimum allowed rate and zero royalty have an exact one-wei funding boundary
    function test_minimumRateFundingEdge() public {
        _thresholdEdge(1, 0);
    }

    // promise: decision 176 the high launch cap and maximum royalty have an exact one-wei funding boundary
    function test_highRateMaximumRoyaltyFundingEdge() public {
        _thresholdEdge(0.0147 ether, 1_000);
    }

    // promise: each sale that leaves less than one 100-point bid pauses the clock until booked ETH refills it
    function test_repeatedEmptyAndRefillDoesNotAccrueIdleHours() public {
        // the room is the pot less the live reserve, so one bid of room sits at reserve + 2 * START
        uint256 res = core.reserve();
        _potTo(res + 2 * START - 1);
        _sellOne();
        uint256 afterFill = core.rateAtCheckpoint();
        assertLt(_room(core.ethPot()), core.floorRate(), "the first sale leaves the pot under its reference bid");
        _warp(6 hours);
        assertEq(core.ethPrice(), afterFill, "the empty hours do not raise the price state");

        _potTo(res + 2 * START);
        assertEq(core.ethPrice(), afterFill, "refilling does not grant the idle six hours");
        _warp(10 minutes);
        uint256 climbed = core.ethPrice();
        assertGt(climbed, afterFill, "the funded interval climbs");
        _sellOne();
        uint256 secondFill = core.rateAtCheckpoint();
        _warp(6 hours);
        assertEq(core.ethPrice(), secondFill, "the next empty interval is paused too");
    }

    // promise: decision 176 a seller cannot use empty hours or changing asks to bypass the bid, reserve, drop or cap
    function test_risingThenFallingListingAsksStayInsideTheBid() public {
        Settings memory s = core.settings();
        s.reserveWei = 0.1 ether;
        _setSettings(s);
        _approveAdapter(rawAdapter);
        _addToPot(0.1 ether + START + START / 2);
        _sellOne();
        uint256 afterDrain = core.rateAtCheckpoint();
        assertLt(core.ethPot() - core.reserve(), afterDrain, "the first purchase drained the 100-point funding room");
        _warp(6 hours);
        _addToPot(1 ether);
        assertEq(core.ethRate(), afterDrain, "refill did not import the six empty hours");

        ListingTarget listing = new ListingTarget();
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = _heldCredit(i);
            _unitScore(ids[i]);
            vm.prank(STRATEGY);
            CREDITS.transferFrom(STRATEGY, address(listing), ids[i]);
        }
        uint256 firstAsk = afterDrain * 3 / 2;
        vm.prank(keeper);
        vm.expectRevert(ICore.AboveBid.selector);
        _buyRaw(firstAsk, abi.encodeCall(ListingTarget.fill, (ids[0], 0)), ids[0], address(listing));

        for (uint256 i; i < 48 && core.bidOf(ids[0]) < firstAsk; ++i) {
            _warp(10 minutes);
        }
        assertGe(core.bidOf(ids[0]), firstAsk, "funded climb can reach a rising ask");
        vm.fee(0);
        uint256 rateBefore = core.ethPrice();
        vm.prank(keeper);
        _buyRaw(firstAsk, abi.encodeCall(ListingTarget.fill, (ids[0], 0)), ids[0], address(listing));
        assertEq(address(listing).balance, firstAsk, "the listing receives its ask, not the higher bid");
        assertLt(core.rateAtCheckpoint(), rateBefore, "the fill drops the bid");

        uint256 higherAsk = afterDrain * 2;
        vm.prank(keeper);
        vm.expectRevert(ICore.AboveBid.selector);
        _buyRaw(higherAsk, abi.encodeCall(ListingTarget.fill, (ids[1], 0)), ids[1], address(listing));
        for (uint256 i; i < 48 && core.bidOf(ids[1]) < higherAsk; ++i) {
            _warp(10 minutes);
        }
        assertGe(core.bidOf(ids[1]), higherAsk, "the bid reaches a second rising ask only with funded time");
        vm.prank(keeper);
        _buyRaw(higherAsk, abi.encodeCall(ListingTarget.fill, (ids[1], 0)), ids[1], address(listing));

        uint256 lowerAsk = afterDrain / 2;
        vm.prank(keeper);
        _buyRaw(lowerAsk, abi.encodeCall(ListingTarget.fill, (ids[2], 0)), ids[2], address(listing));
        assertEq(address(listing).balance, firstAsk + higherAsk + lowerAsk, "falling ask is paid at its live quote");
        assertGe(core.ethPot(), core.reserve(), "the reserve remains funded after the purchase sequence");
        assertLe(core.ethRate(), core.settings().rateCap, "the hard cap survives the price path");
    }

    // promise: SPEC 1 the price state stays at or below rateCap (inv 19)
    /// a year of idle loosening never takes the rate above `rateCap`
    function test_loosenedCeilingNeverPassesTheRateCap() public {
        _potTo(20 ether);
        _sellOne();
        _warp(365 days);
        assertEq(core.ethRate(), core.settings().rateCap);
    }

    // ------------------------------------------------------------------ fills and the anchor

    function _listingData(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeCall(ICreditStrategy.sellTargetNFT, (id));
    }

    function _forListing() internal returns (uint256 price) {
        _with(_openCeiling);
        _potTo(30 ether);
        // LISTED_A (35377) is burned before the pin, so the still-listed LISTED_B is bought. the listed credit is mocked
        // to 100 points, so its bid is the full rate and the fill drops by dropPer100PointsBps
        _unitScore(LISTED_B);
        price = ICreditStrategy(STRATEGY).nftForSale(LISTED_B);
        _liftRateCap();
        _warpUntilCeiling(LISTED_B, price);
    }

    // promise: SPEC 1 buyListing is one fill at the bid
    /// `buyListing` is one fill: the rate drops once and the anchor is the bid rate at that moment, not the cost
    function test_buyListingIsOneFillAndTheAnchorIsTheBidRate() public {
        uint256 price = _forListing();
        uint256 rate = core.ethRate();
        vm.prank(keeper);
        _buyRaw(price, _listingData(LISTED_B), LISTED_B, STRATEGY);
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, rate, "the anchor is the bid rate");
        assertEq(start, rate);
        assertTrue(anchor != price, "not derived from the cost");
        assertEq(core.rateAtCheckpoint(), _unitDrop(rate), "one live drop below the bid rate");
        assertEq(core.lastFillTime(), block.timestamp);
    }

    // promise: setRate restates the bid and starts a fresh funded ceiling clock
    function test_setRateRestatesTheRateAndTheAnchorAndKeepsTheFillClock() public {
        _with(_twoPercentLoosening);
        // a pot under one page (above the live reserve so the fill passes) keeps the multiplier at 1x, so the ceiling
        // loosens at the base 2 percent per 10 minutes
        _potTo(core.reserve() + 0.1 ether);
        _sellOne();
        uint64 fillTime = core.lastFillTime();
        (, uint256 start0, uint256 bucket0) = _anchor();
        _warp(30 minutes);
        vm.prank(owner);
        core.setRate(2.6e15);
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(core.rateAtCheckpoint(), 2.6e15);
        assertEq(anchor, 2.6e15);
        assertEq(core.lastFillTime(), fillTime);
        assertTrue(start == start0 && bucket == bucket0, "the minute state is unchanged");
        assertEq(core.ethRate(), 2.6e15);
        // the ceiling follows the restated anchor from the setRate time, while lastFillTime remains the actual fill
        _warp(1 days);
        assertEq(core.ethRate(), 2.6e15 * (10_000 + 200 * 144) * 11_000 / 1e8);
    }

    // ------------------------------------------------------------------ gap in the market price

    /// @dev the first minute after a jump of the market at which the bid reaches the cheapest ask, `askMultiple` bps of
    /// the rate paid at the last fill, at the launch loosening. a 20 eth pot, one fill before the jump
    function _minutesToFirstFill(uint256 askMultiple) internal returns (uint256 minutes_, uint256 anchor) {
        _potTo(20 ether);
        _warp(1 hours);
        _sellOne();
        (anchor,,) = _anchor();
        uint256 ask = anchor * askMultiple / 10_000;
        for (uint256 m = 1; m <= 600; ++m) {
            _warp(60);
            if (core.ethRate() >= ask) return (m, anchor);
        }
    }

    // promise: SPEC 1 risk: a market above the bid waits for the climb or setRate
    /// every seller asks the full new price, 200 percent of the old one. the 20 eth pot loosens the ceiling at the 4x
    /// cap, so the ceiling clears 200 percent within minutes, but the per minute climb is unscaled (decision 128 variant
    /// d, climbPerMinBps 100 live, pin 26242107): the bid reaches 200 percent only when the 1 percent a minute climb
    /// gets there. from the post-drop rate (0.9971 of the anchor) that is minute 70 (0.9971 * 1.01^70 first passes 2x)
    function test_gapUp100Percent_everyAskAtTheNewPriceWaitsForTheClimb() public {
        (uint256 m,) = _minutesToFirstFill(20_000);
        emit log_named_uint("minutes to the first fill, no cheap ask", m);
        assertEq(m, 70);
    }

    // ------------------------------------------------------------------ decision 128: pot scaled climb

    function _highCeiling(Settings memory s) internal pure {
        s.ceilBps = 30_000;
    }

    /// @dev one minute of idle climb at a pot sized to `pages` pages (one page is `pointsPerPage` points at the stored
    /// rate). returns the realized per minute growth in bps over the stored rate, 10_000 being 1x. the pot override
    /// sets the multiplier to `clamp(pages, 1, 4)` exactly; a high ceiling keeps the one minute climb off the ceiling
    function _climbFactorBps(uint256 pages) internal returns (uint256) {
        _potTo(1 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        uint256 stored = core.rateAtCheckpoint();
        // the multiplier reads the last fill rate (the anchor); a pot of `pages` pages at the anchor sets it to `pages` exactly
        uint256 pot = pages * anchor * core.settings().pointsPerPage / 100;
        stdstore.target(address(core)).sig("ethPot()").checked_write(pot);
        vm.deal(address(core), pot);
        _warp(60);
        return core.ethPrice() * 10_000 / stored;
    }

    // promise: SPEC 4 decision 128 variant d: the per minute climb does not scale with the pot, only the loosening does
    /// the climb is the live rate (climbPerMinBps 100, 1 percent a minute) at one, three and ten pages alike. one minute
    /// of continuous climb grows the rate by `climbPerMinBps` bps, so the factor is `10_000 + climbPerMinBps`
    function test_climbUnscaledByPotPages() public {
        _with(_highCeiling);
        uint256 oneMin = 10_000 + core.settings().climbPerMinBps;
        assertApproxEqAbs(_climbFactorBps(1), oneMin, 2, "one page climbs at 1x");
        assertApproxEqAbs(_climbFactorBps(3), oneMin, 2, "three pages climb at the same 1x");
        assertApproxEqAbs(_climbFactorBps(10), oneMin, 2, "ten pages climb at the same 1x");
    }

    /// @dev the loosened ceiling after 10 idle minutes at a pot sized to `pages` pages, in bps of the anchor (10_000
    /// being the base). a fast climb pins the read to the ceiling; the pot override sets the multiplier exactly
    function _loosenBps(uint256 pages) internal returns (uint256) {
        Settings memory s = core.settings();
        s.climbPerMinBps = 1_000;
        s.recoveryClimbPerMinBps = 1_000;
        _setSettings(s);
        _potTo(1 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        // a pot of `pages` pages at the last fill rate (the anchor the multiplier reads) sets the multiplier to `pages` exactly
        uint256 pot = pages * anchor * core.settings().pointsPerPage / 100;
        stdstore.target(address(core)).sig("ethPot()").checked_write(pot);
        vm.deal(address(core), pot);
        _warp(10 minutes);
        return core.ethRate() * 1e8 / (anchor * core.settings().ceilBps);
    }

    // promise: SPEC 4 decision 128 variant d: the ceiling's idle loosening scales with the pages the pot covers, clamped to [1x, the cap]
    /// the launch loosening is 6 percent per 10 minutes (idleLoosenBps 600); at three pages it is 18 percent, at ten
    /// pages the 4x cap, 24 percent
    function test_ceilingLooseningScalesWithPotPages() public {
        assertEq(core.settings().idleLoosenBps, 600);
        assertApproxEqAbs(_loosenBps(1), 10_600, 2, "one page loosens 6 percent per 10 minutes");
        assertApproxEqAbs(_loosenBps(3), 11_800, 2, "three pages loosen 18 percent");
        assertApproxEqAbs(_loosenBps(10), 12_400, 2, "ten pages loosen at the 4x cap, 24 percent");
    }

    // promise: SPEC 4 decision 128: a full pot runs the idle loosening at the 4x cap
    /// a fill then four hours idle at a full pot (the 4x cap): the ceiling grows per the pot scaled loosening, 24 idle
    /// intervals of 600 * 4 bps, with no hourly cap (the hourly bound was rejected, decision 128)
    function test_fullPotLoosensAtTheCapOverFourHours() public {
        // a fast climb so the read pins to the loosened ceiling (the launch 200 climb stays below it); the loosening is
        // what the 4x pot multiplier scales
        Settings memory s = core.settings();
        s.climbPerMinBps = 1_000;
        s.recoveryClimbPerMinBps = 1_000;
        _setSettings(s);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(4 hours);
        assertEq(
            core.ethRate(), anchor * (10_000 + 600 * 4 * 24) * 11_000 / 1e8, "the ceiling grows per the 4x loosening"
        );
    }

    address internal pumpAttacker;

    /// @dev sells all of `ids` into the eth bid for the pump attacker, returns the eth received
    function _sellAll(uint256[] memory ids) internal returns (uint256) {
        vm.startPrank(pumpAttacker);
        CREDITS.setApprovalForAll(address(core), true);
        uint256 before = pumpAttacker.balance;
        core.sellForEth(ids);
        uint256 got = pumpAttacker.balance - before;
        vm.stopPrank();
        return got;
    }

    /// @dev the marginal gain of pumping the pot: the attacker holds 20 credits over a pot under one page (so without a
    /// pump the climb runs at 1x), waits 40 minutes (far under the ~4.5 hours a 1x climb needs to reach rateCap, so the
    /// multiplier is what moves the bid), and sells. returns the extra eth the sale earns with the pump over the same
    /// sale without it, and the fee the attacker paid (the engine's capture of a swap skim, or the whole `fund` donation)
    function _pumpMarginal(bool useFund, uint256 pumpEth) internal returns (uint256 gain, uint256 feePaid) {
        pumpAttacker = _user("pump.attacker");
        uint256[] memory ids = _credits(pumpAttacker, 20);
        // under one page (about 2 eth at the opening rate) so the unpumped climb is 1x, and above the 20 credits' bids
        // so no sale clamps on the pot (a credit above 100 points bids more than the per-100-point rate)
        _potTo(0.7 ether);
        uint256 snap = vm.snapshotState();
        _warp(40 minutes);
        uint256 noPump = _sellAll(ids);
        vm.revertToState(snap);
        uint256 engineBefore = core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn();
        if (useFund) {
            vm.deal(pumpAttacker, pumpEth);
            vm.prank(pumpAttacker);
            core.fund{value: pumpEth}();
            feePaid = pumpEth; // a `fund` donation books whole to the pot and is not recoverable
        } else {
            _buyCoin(pumpAttacker, pumpEth);
            feePaid = core.ethPot() + core.ethToBuyback() + core.ethRedeemBurn() - engineBefore;
        }
        _warp(40 minutes);
        uint256 withPump = _sellAll(ids);
        gain = withPump > noPump ? withPump - noPump : 0;
    }

    // promise: SPEC 4 decision 128: pumping the pot to inflate the bid through the multiplier is unprofitable
    /// a swap of 50 eth fills the pot through the skim and raises the multiplier from 1x to 4x; the extra the attacker
    /// earns selling 20 credits at the faster bid, over the same sale without the pump, is below the skim the attacker fed
    function test_pumpViaSwapIsUnprofitable() public {
        _skipSniperWindow();
        (uint256 gain, uint256 feePaid) = _pumpMarginal(false, 50 ether);
        emit log_named_uint("swap pump: marginal gain over no pump (wei)", gain);
        emit log_named_uint("swap pump: fee fed to the engine (wei)", feePaid);
        assertLt(gain, feePaid, "the swap pump marginal gain is below the fee paid");
    }

    // promise: SPEC 4 decision 128: a fund() pump is unprofitable
    /// a `fund` donation raises the multiplier but is not recoverable; the marginal gain is below the donation
    function test_pumpViaFundIsUnprofitable() public {
        _skipSniperWindow();
        (uint256 gain, uint256 feePaid) = _pumpMarginal(true, 1 ether);
        emit log_named_uint("fund pump: marginal gain over no pump (wei)", gain);
        emit log_named_uint("fund pump: donation (wei)", feePaid);
        assertLt(gain, feePaid, "the fund pump marginal gain is below the donation");
    }

    // promise: SPEC 4 decision 128: a pump during the sniper window is unprofitable
    /// the anti sniper skim makes a swap in the window cost more, so the marginal gain stays below the fee
    function test_pumpInSniperWindowIsUnprofitable() public {
        (uint256 gain, uint256 feePaid) = _pumpMarginal(false, 50 ether);
        emit log_named_uint("sniper pump: marginal gain over no pump (wei)", gain);
        emit log_named_uint("sniper pump: fee fed to the engine (wei)", feePaid);
        assertLt(gain, feePaid, "the sniper-window pump marginal gain is below the fee paid");
    }

    // ------------------------------------------------------------------ the unbooked drip (decision 147), launch settings

    /// @dev the unbooked fee income: the Core balance above the three pots
    function _pending() internal view returns (uint256) {
        return address(core).balance - core.ethPot() - core.ethToBuyback() - core.ethRedeemBurn();
    }

    /// @dev the pot share of the pending income that the next `_book` folds into `ethPot`: the payee share while
    /// latched, then the redeem burn reserve share of the rest, the remainder to the pot
    function _pendingPot() internal view returns (uint256) {
        Settings memory s = core.settings();
        uint256 income = _pending();
        uint256 toPayee = core.payeeOn() ? income * s.payeePpm / 1_000_000 : 0;
        uint256 toBurn = (income - toPayee) * s.feeToRedeemBurnBps / 10_000;
        return income - toPayee - toBurn;
    }

    // promise: unbooked fees cannot accelerate the funded clock or its ceiling
    function test_unbookedDripDoesNotScaleTheMultiplierAndLoosening() public {
        Settings memory s = core.settings();
        s.climbPerMinBps = 1_000;
        s.recoveryClimbPerMinBps = 1_000;
        _setSettings(s);
        _skipSniperWindow();
        // a booked pot under one page (above the live reserve so the fill passes) keeps the multiplier at 1x without
        // the drip; one fill sets the anchor
        _potTo(core.reserve() + 0.1 ether);
        _sellOne();
        uint256 snap = vm.snapshotState();

        // no drip: an idle hour at the small booked pot
        _warp(1 hours);
        uint256 rate0 = core.ethRate();
        uint256 mult0 = core.climbMultiplier();
        uint256 floor0 = core.floorRate();
        assertEq(mult0, 10_000, "the small booked pot keeps the multiplier at 1x");
        vm.revertToState(snap);

        // the drip: six buys left unbooked, then the same idle hour
        autoBook = false;
        uint256 potBooked = core.ethPot();
        for (uint256 i; i < 6; ++i) {
            _buyCoin(funder, 3 ether);
        }
        assertEq(core.ethPot(), potBooked, "no door booked, the drip waits above the pots");
        assertGt(_pending(), 0, "the hook pushed fee income");
        _warp(1 hours);
        uint256 rate1 = core.ethRate();
        uint256 mult1 = core.climbMultiplier();
        uint256 floor1 = core.floorRate();

        assertEq(mult1, mult0, "pending fees do not increase the booked pot multiplier");
        assertEq(rate1, rate0, "pending fees do not accelerate the price clock");
        assertEq(floor1, floor0, "pending fees do not loosen the ceiling");
        // the read rides the pot plus the pending pot share (decision 147), never above it
        assertLe(rate1, core.ethPot() + _pendingPot(), "the read stays inside the pending pot clamp");
    }

    // promise: a booked pot keeps climbing, while unbooked fees do not change its multiplier
    function test_bookedPotClimbsWithPendingFees() public {
        _with(_openCeiling);
        _skipSniperWindow();
        _potTo(1 ether);
        _sellOne();
        autoBook = false;
        uint256 potBooked = core.ethPot();
        uint256 multiplier = core.climbMultiplier();
        uint256 last = core.ethRate();
        for (uint256 i; i < 3; ++i) {
            _buyCoin(funder, 1 ether);
            assertEq(core.ethPot(), potBooked, "no book folded the income into the pot");
            _warp(1 hours);
            uint256 r = core.ethRate();
            assertGt(r, last, "the booked pot funds the climb without another fill");
            assertEq(core.climbMultiplier(), multiplier, "pending fees do not scale the multiplier");
            assertLe(r, core.ethPot() + _pendingPot(), "the climb rides the pot plus the pending pot share");
            last = r;
        }
    }

    // promise: SPEC 1 a fill after idle time runs at the climbed rate and leaves it as the anchor and peak
    /// the fixture's `_fillEthPile` restates the price to the opening rate with `setRate` before a fill, which erases the
    /// idle climb. this fills after idle time with no restatement: the fill pays the climbed rate and leaves that rate
    /// as the anchor, the minute start and the remembered peak, with one launch drop stored. launch settings
    function test_fillAfterIdleTimeUsesTheClimbedRateAsTheAnchorAndPeak() public {
        _skipSniperWindow();
        _potTo(20 ether);
        _sellOne();
        _warp(2 hours);
        uint256 climbed = core.ethRate();
        (uint256 anchorBefore,,) = _anchor();
        assertGt(climbed, anchorBefore, "the rate climbed above the last fill rate over the idle hours");

        uint256 id = _credits(seller, 1)[0];
        _unitScore(id);
        uint256 quote = core.ethRate();
        assertEq(quote, climbed, "no time passed between the read and the fill");
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        assertEq(seller.balance - before, quote, "the fill paid the climbed rate, not a restated opening rate");

        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, climbed, "the anchor is the climbed rate paid");
        assertEq(start, climbed, "and the minute start");
        (uint256 peakRate, uint256 peakTime) = _peak();
        assertEq(peakRate, climbed, "the remembered peak is the climbed rate");
        assertEq(peakTime, block.timestamp, "the peak time is the fill");
        assertEq(core.rateAtCheckpoint(), _unitDrop(climbed), "one live drop below the climbed rate");
    }

    // promise: an expired bucket's cleared anchor starts a fresh drop floor on its first fill
    function test_modelRestartsClearedDropAnchor() public pure {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPer100PointsBps = 10_000;
        s.dropFloorBps = 5_000;
        uint256 start = BidModel.startAfter(s, 1_000, 0);
        assertEq(start, 1_000);
        assertEq(BidModel.dropOnce(s, 1_000, start, RATE_SCORE), 500);
    }
}

/// @notice the live counterpart of the ratio-1 mechanics above. the drop and climb code paths are the same; here they
/// run against the live Core with a real credit (its real score, never forced to 100 points) and the live settings read
/// at setUp, so the scaled drop uses the live `dropPer100PointsBps` (29) scaled by the credit's score. the exact
/// launch-settings numbers (110 percent ceiling, the 6 percent loosening, the ratio-1 fill counts) are not reproducible
/// here and stay in `BidRuleTest`; this contract proves the mechanics hold live, computing every expectation from the
/// live rate and settings
contract BidRuleLiveTest is LiveFixture {
    // the price state after one credit of score `s` bought at state `r`, minute start `start` (CoreLib.drop by hand)
    function _dropHand(uint256 r, uint256 s, uint256 start) internal view returns (uint256) {
        uint256 drop = core.settings().dropPer100PointsBps;
        uint256 floorBps = core.settings().dropFloorBps;
        uint256 fallNum = drop * s;
        uint256 denom = 10_000 * RATE_SCORE;
        uint256 dropped = fallNum >= denom ? 0 : (r * (denom - fallNum)) / denom;
        uint256 floor = (start * floorBps) / 10_000;
        return dropped > floor ? dropped : floor;
    }

    // promise: SPEC 1 the bid rule: a fill drops the price state by dropPer100PointsBps scaled by the credit's score
    /// a real credit's eth bid is the live rate scaled by its score, and a fill drops the price state by the live
    /// `dropPer100PointsBps` scaled by that score, leaving the rate paid as the anchor and minute start. the ratio-1
    /// counterpart with the exact launch drop is BidRuleTest.test_oneFillDropsTheLaunchDrop
    function test_liveFillDropsTheScaledDropAndSetsTheAnchor() public {
        _skipSniperWindow();
        _fundPot(20 ether);
        uint256 id = _credits(seller, 1)[0];
        uint256 score = _scoreOf(id);
        uint256 r0 = core.ethRate();
        assertEq(core.bidOf(id), r0 * score / RATE_SCORE, "the per-credit bid is the rate scaled by score");

        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        assertEq(seller.balance - before, r0 * score / RATE_SCORE, "the seller is paid the scaled bid");

        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, r0, "the rate paid per 100 points is the anchor");
        assertEq(start, r0, "and the start of the minute");
        assertEq(core.lastFillTime(), block.timestamp, "the fill time is now");
        assertEq(core.rateAtCheckpoint(), _dropHand(r0, score, r0), "the fall scales the live drop by score");
    }

    // promise: SPEC 1 the price state climbs over idle time and never passes the rate cap (inv 19)
    /// a fill after funding the pot sets the anchor; the booked pot then climbs the bid over idle time, bounded by the
    /// loosened ceiling, and a year of idle loosening rests at the live `rateCap`. the ratio-1 counterparts are
    /// BidRuleTest.test_ceilingHoldsAt110PercentOfTheAnchor and test_loosenedCeilingNeverPassesTheRateCap
    function test_liveClimbRaisesTheBidAndHoldsUnderTheRateCap() public {
        _skipSniperWindow();
        _fundPot(20 ether);
        uint256 id = _credits(seller, 1)[0];
        vm.prank(seller);
        core.sellForEth(_one(id));

        uint256 afterFill = core.ethRate();
        _warp(2 hours);
        uint256 climbed = core.ethRate();
        assertGt(climbed, afterFill, "the booked pot climbs the bid over idle time");
        assertLe(climbed, core.settings().rateCap, "the climb never passes the rate cap");

        _warp(365 days);
        assertEq(core.ethRate(), core.settings().rateCap, "a year of idle loosening rests at the rate cap");
    }
}
