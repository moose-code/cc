// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Settings, Mainnet, ICreditStrategy} from "../src/interfaces/Interfaces.sol";

/// @notice the credit bid rule on the real stack: the drop per credit with its minute floor, the compounded climb per
/// minute, the ceiling at a share of the last rate paid with its idle loosening, the funded clamp (the price of one credit
/// that the pot affords), the settings bounds, and the recovery after a gap in the market price. exact numbers at the launch
/// settings, hand arithmetic throughout
contract BidRuleTest is Fixture {
    using stdStorage for StdStorage;

    uint256 internal constant START = OPEN_RATE;

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

    function _sellOne() internal returns (uint256 price) {
        uint256 id = _credits(seller, 1)[0];
        price = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    // ------------------------------------------------------------------ drop

    // promise: SPEC 1 the bid rule: a fill drops the price state by dropPerCreditBps
    function test_oneFillDropsHalfAPercent() public {
        _potTo(10 ether);
        uint256 r0 = core.ethRate();
        assertEq(r0, START);
        uint256 price = _sellOne();
        assertEq(price, r0, "the rate before the fill");
        assertEq(core.rateAtCheckpoint(), r0 * 9_950 / 10_000, "0.5 percent below the rate paid");
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, r0, "the rate paid is the anchor");
        assertEq(start, r0, "and the start of the minute");
        assertEq(bucket, block.timestamp / 60);
        assertEq(core.lastFillTime(), block.timestamp);
    }

    // promise: SPEC 1 the bid rule at launch: dropFloorBps 5_000 bounds the drop inside a minute
    /// at the launch drop of 0.5 percent the floor of 50 percent is reached after 139 fills in one minute
    function test_launchDropReachesTheFloorAfterHundredThirtyNineFills() public {
        _potTo(40 ether);
        uint256 r0 = core.ethRate();
        uint256[] memory ids = _credits(seller, 140);
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            if (i == 137) assertGt(core.rateAtCheckpoint(), r0 * 5_000 / 10_000, "138 fills are above the floor");
        }
        assertEq(core.rateAtCheckpoint(), r0 * 5_000 / 10_000, "140 fills sit on the floor");
    }

    // ------------------------------------------------------------------ climb

    // promise: inv 19 the read is at most the price state and follows the pot
    /// the read does not fall as the pot grows and never exceeds the price state
    function test_readIsMonotoneInThePot() public {
        uint256 last;
        for (uint256 i; i <= 40; ++i) {
            _potTo(i * 0.05e15);
            uint256 read = core.ethRate();
            assertGe(read, last, "the read does not fall as the pot grows");
            assertLe(read, core.rateAtCheckpoint(), "the read is at most the price state");
            last = read;
        }
        assertEq(last, START, "a pot of 2e15 wei reads the price state");
        // one wei of pot on either side of the pot that reads the price state
        uint256 full = START;
        assertEq(core.ethPot(), 2e15);
        stdstore.target(address(core)).sig("ethPot()").checked_write(full - 1);
        vm.deal(address(core), full - 1);
        assertEq(core.ethRate(), START - 1, "one wei under the pot that reads the price state");
    }

    // ------------------------------------------------------------------ ceiling

    // promise: SPEC 1 the bid rule at launch: ceilBps 11_000
    /// the rate stops at 110 percent of the anchor grown by the loosening (the minimum setting, 1 basis point per 10
    /// idle minutes): the anchor is the rate paid at the last fill
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
        assertEq(core.ethRate(), r0 * (10_000 + 18) * 11_000 / 1e8, "110 percent of the rate paid, 18 intervals of 1 bp");
        _warp(30 days);
        assertEq(core.ethRate(), r0 * (10_000 + 4_338) * 11_000 / 1e8, "4,338 intervals after 30 days and 3 hours");
        assertEq(core.rateAtCheckpoint(), r0 * 9_950 / 10_000, "stored until the next checkpoint");
    }

    function _minLoosening(Settings memory s) internal pure {
        s.idleLoosenBps = 1;
    }

    /// the loosening the mechanics tests below are written against: 2 percent per 10 idle minutes
    function _twoPercentLoosening(Settings memory s) internal pure {
        s.idleLoosenBps = 200;
    }

    // promise: SPEC 1 the bid rule at launch: idleLoosenBps 200
    /// the launch setting: the anchor grows 2 percent per full 10 idle minutes (FLOW decision 69)
    function test_anchorLoosensTwoPercentPerTenIdleMinutesAtLaunch() public {
        assertEq(core.settings().idleLoosenBps, 200);
        _with(_fastClimbOnly);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(9 minutes + 59);
        assertEq(core.settings().ceilBps, 11_000);
        assertEq(core.ethRate(), anchor * 11_000 / 10_000, "no loosening before 10 idle minutes");
        _warp(1);
        assertEq(core.ethRate(), anchor * 10_200 * 11_000 / 1e8, "2 percent after 10 minutes");
        _warp(10 minutes);
        assertEq(core.ethRate(), anchor * 10_400 * 11_000 / 1e8, "4 percent after 20 minutes");
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
        assertEq(r, anchorBefore * 10_800 * 11_000 / 1e8, "loosened 8 percent");
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
        _potTo(START / 2);
        _warp(3 days);
        uint256 clamp = core.ethPot();
        assertEq(core.ethRate(), clamp, "held at the clamp");
        _warp(30 days);
        assertEq(core.ethRate(), clamp);
        // more fees lift the clamp, the climb resumes from the stored rate
        _potTo(START * 3 / 4);
        uint256 clamp2 = core.ethPot();
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
        s.dropPerCreditBps = 0;
        _expectBad(s, "dropPerCreditBps");
        s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 1_001;
        _expectBad(s, "dropPerCreditBps");
        s = Mainnet.defaultSettings();
        s.dropFloorBps = 4_999;
        _expectBad(s, "dropFloorBps");
        s = Mainnet.defaultSettings();
        s.dropFloorBps = 10_001;
        _expectBad(s, "dropFloorBps");
        s = Mainnet.defaultSettings();
        s.climbPerMinBps = 0;
        _expectBad(s, "climbPerMinBps");
        s = Mainnet.defaultSettings();
        s.climbPerMinBps = 1_001;
        _expectBad(s, "climbPerMinBps");
        s = Mainnet.defaultSettings();
        s.ceilBps = 9_999;
        _expectBad(s, "ceilBps");
        s = Mainnet.defaultSettings();
        s.ceilBps = 30_001;
        _expectBad(s, "ceilBps");
        s = Mainnet.defaultSettings();
        s.idleLoosenBps = 0;
        _expectBad(s, "idleLoosenBps");
        s = Mainnet.defaultSettings();
        s.idleLoosenBps = 2_001;
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
        // drain the pot to under one credit, then book 1 wei so that a checkpoint runs at the small pot
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(1e15));
        vm.deal(address(core), 1e15 + 1);
        core.book();
        assertEq(core.ethPot(), 1e15 + 1);
        assertEq(core.rateAtCheckpoint(), price, "the price state is not lowered by the small pot");
        _warp(10 hours);
        assertEq(core.ethRate(), core.ethPot(), "the read is the clamp of the small pot");
        _addToPot(1);
        assertEq(core.rateAtCheckpoint(), price, "and a starved pot does not raise the price state");
        _potTo(20 ether);
        assertEq(core.rateAtCheckpoint(), price, "the checkpoint at the refill stores the price from before");
        assertEq(core.ethRate(), price, "the read after the refill is that price");
        _warp(10 minutes);
        // 1.005^10 = 1.0511401320407896
        assertApproxEqRel(core.ethRate(), price * 1_051_140_132_040_790_000 / 1e18, 1e9, "and it climbs from there");
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
        price = ICreditStrategy(STRATEGY).nftForSale(LISTED_A);
        _liftRateCap();
        _warpUntilCeiling(LISTED_A, price);
    }

    // promise: SPEC 1 buyListing is one fill at the bid
    /// `buyListing` is one fill: the rate drops once and the anchor is the bid rate at that moment, not the cost
    function test_buyListingIsOneFillAndTheAnchorIsTheBidRate() public {
        uint256 price = _forListing();
        uint256 rate = core.ethRate();
        vm.prank(keeper);
        _buyRaw(price, _listingData(LISTED_A), LISTED_A, STRATEGY);
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, rate, "the anchor is the bid rate");
        assertEq(start, rate);
        assertTrue(anchor != price, "not derived from the cost");
        assertEq(core.rateAtCheckpoint(), rate * 9_950 / 10_000, "one drop of 0.5 percent");
        assertEq(core.lastFillTime(), block.timestamp);
    }

    // promise: SPEC 1 setRate restores the bid at once
    /// `setRate` restates the price: the stored rate and the ceiling anchor are both the new rate, the fill clock and
    /// the minute start stay
    function test_setRateRestatesTheRateAndTheAnchorAndKeepsTheFillClock() public {
        _with(_twoPercentLoosening);
        _potTo(20 ether);
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
        // the ceiling follows the restated anchor: 110 percent, plus 3 intervals of 2 percent after 30 idle minutes
        _warp(1 days);
        assertEq(core.ethRate(), 2.6e15 * (10_000 + 200 * 147) * 11_000 / 1e8);
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
    /// every seller asks the full new price, 200 percent of the old one: at the launch loosening the ceiling clears
    /// 200 percent at the 41st interval (110 percent * (1 + 2 percent * 41)), 410 minutes, a little under 7 hours. the
    /// climb alone would reach it at minute 139 (0.995 * 1.005^m >= 2)
    function test_gapUp100Percent_everyAskAtTheNewPriceWaitsForTheClimb() public {
        (uint256 m,) = _minutesToFirstFill(20_000);
        emit log_named_uint("minutes to the first fill, no cheap ask", m);
        assertEq(m, 410);
    }

}
