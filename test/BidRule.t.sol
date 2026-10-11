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
        vm.deal(address(core), address(core).balance + (eth - have));
        core.skim();
    }

    function _with(function(Settings memory) pure f) internal {
        Settings memory s = core.settings();
        f(s);
        _setSettings(s);
    }

    function _sellOne() internal returns (uint256 price) {
        uint256 id = _credits(seller, 1)[0];
        price = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    // ------------------------------------------------------------------ drop

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

    /// 30 fills in one minute at 1 percent each stop at an 80 percent floor of the first rate paid
    function test_thirtyFillsInOneMinuteStopAtTheFloor() public {
        _with(_onePercentDropFloor80);
        _potTo(20 ether);
        uint256 r0 = core.ethRate();
        uint256[] memory ids = _credits(seller, 30);
        uint256 floorRate = r0 * 8_000 / 10_000;
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
            uint256 r = core.rateAtCheckpoint();
            assertGe(r, floorRate, "never below the minute floor");
            // 0.99^i of the first rate until the floor
            if (i < 22) assertEq(r, _walk(r0, i + 1, 100));
        }
        assertEq(core.rateAtCheckpoint(), floorRate, "sits on the floor");
        (, uint256 start,) = _anchor();
        assertEq(start, r0);
    }

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

    /// a new minute starts the floor from the first rate paid in it
    function test_nextMinuteStartsANewFloor() public {
        _with(_onePercentDrop);
        _potTo(20 ether);
        uint256[] memory ids = _credits(seller, 40);
        for (uint256 i; i < 30; ++i) {
            vm.prank(seller);
            core.sellForEth(_one(ids[i]));
        }
        uint256 first = core.rateAtCheckpoint();
        _warp(60);
        uint256 paid = core.ethRate();
        assertGt(paid, first, "the rate climbed during the minute");
        vm.prank(seller);
        core.sellForEth(_one(ids[30]));
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, paid);
        assertEq(start, paid, "the first fill of the new minute starts the floor");
        assertEq(bucket, block.timestamp / 60);
        assertEq(core.rateAtCheckpoint(), paid * 9_900 / 10_000);
    }

    function _onePercentDropFloor80(Settings memory s) internal pure {
        s.dropPerCreditBps = 100;
        s.dropFloorBps = 8_000;
    }

    function _onePercentDrop(Settings memory s) internal pure {
        s.dropPerCreditBps = 100;
    }

    /// @dev the rate after `n` fills of `bps` each from `r`, rounded down at every fill
    function _walk(uint256 r, uint256 n, uint256 bps) internal pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            r = r * (10_000 - bps) / 10_000;
        }
        return r;
    }

    // ------------------------------------------------------------------ climb

    /// after a fill the rate climbs 0.5 percent a minute compounded, 10 minutes is 1.005^10
    function test_climbAfterTenMinutesMatchesTheFormula() public {
        _potTo(20 ether);
        _sellOne();
        uint256 r1 = core.rateAtCheckpoint();
        _warp(10 minutes);
        // 1.005^10 = 1.0511401320407896
        assertApproxEqRel(core.ethRate(), r1 * 1_051_140_132_040_790_000 / 1e18, 1e9);
        _warp(10 minutes);
        assertApproxEqRel(core.ethRate(), r1 * 1_104_895_577_186_790_000 / 1e18, 1e9, "20 minutes is 1.005^20");
    }

    /// the price state does not climb while the pot cannot afford one credit at the stored rate, and the read is
    /// the clamp of the pot
    function test_climbTargetIsTheClamp() public {
        _potTo(1e15);
        _warp(2 hours);
        assertEq(core.ethRate(), 1e15, "the read is the clamp");
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        assertEq(core.rateAtCheckpoint(), START, "the price state did not climb");
    }

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

    /// the anchor grows 2 percent per full 10 idle minutes: 2 percent after 10 minutes, 4 percent after 20
    function test_anchorLoosensTwoPercentPerTenIdleMinutes() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(9 minutes + 59);
        assertEq(core.ethRate(), anchor * 11_000 / 10_000, "no loosening before 10 idle minutes");
        _warp(1);
        assertEq(core.ethRate(), anchor * 10_200 * 11_000 / 1e8, "2 percent after 10 minutes");
        _warp(10 minutes - 1);
        assertEq(core.ethRate(), anchor * 10_200 * 11_000 / 1e8, "and until 20 minutes");
        _warp(1);
        assertEq(core.ethRate(), anchor * 10_400 * 11_000 / 1e8, "4 percent after 20 minutes");
        _warp(100 minutes);
        assertEq(core.ethRate(), anchor * 12_400 * 11_000 / 1e8, "24 percent after 120 minutes");
    }

    function _fastClimb(Settings memory s) internal pure {
        s.climbPerMinBps = 1_000;
        s.idleLoosenBps = 200;
    }

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

    function test_boundEdgesAreAccepted() public {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 1;
        s.dropFloorBps = 5_000;
        s.climbPerMinBps = 1;
        s.ceilBps = 10_000;
        s.idleLoosenBps = 1;
        _setSettings(s);
        assertEq(abi.encode(core.settings()), abi.encode(s));
        s.dropPerCreditBps = 1_000;
        s.dropFloorBps = 10_000;
        s.climbPerMinBps = 1_000;
        s.ceilBps = 30_000;
        s.idleLoosenBps = 2_000;
        _setSettings(s);
        assertEq(abi.encode(core.settings()), abi.encode(s));
    }

    // ------------------------------------------------------------------ hard bounds

    /// the clamp lowers the read only: after a fill shrinks the pot the read is the clamp and the stored price state is
    /// the dropped rate. a second fill pays the clamp, drops the price state as a fill at full price would, and the
    /// anchor is the price state at that fill
    function test_clampLowersTheReadAndNotThePriceState() public {
        // a pot of 1.5 credits at the opening rate: the clamp is 1.5 times the rate and the read is the price state
        _potTo(START * 3 / 2);
        assertEq(core.ethRate(), START);
        _sellOne();
        uint256 price1 = START * 9_950 / 10_000;
        assertEq(core.rateAtCheckpoint(), price1, "the price state dropped 0.5 percent");
        uint256 clamp = core.ethPot();
        assertLt(clamp, price1, "the clamp of the smaller pot is below the price state");
        assertEq(core.ethRate(), clamp, "and the read is the clamp");
        // the next fill pays the clamp
        uint256 id = _credits(seller, 1)[0];
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        assertEq(seller.balance - before, clamp, "paid at the clamp");
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, price1, "the anchor is the price state at the fill, not the rate paid");
        assertEq(start, START, "the minute started at the first price state");
        assertEq(core.rateAtCheckpoint(), price1 * 9_950 / 10_000, "the drop is the one of a fill at full price");
    }

    /// a checkpoint at a small funded pot stores the price state, not the clamp: when the pot grows the read is back at
    /// the opening rate at once
    function test_launch_smallPotDoesNotDragThePriceState() public {
        _potTo(0.0005 ether);
        core.skim();
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        uint256 clamp = core.ethPot();
        assertLt(clamp, START / 3, "the clamp is a fraction of the opening rate");
        assertEq(core.ethRate(), clamp);
        assertEq(core.rateAtCheckpoint(), START, "the checkpoint stored the price state");
        _potTo(100 ether);
        assertEq(core.rateAtCheckpoint(), START);
        assertEq(core.ethRate(), START, "back at the opening rate");
        _warp(30);
        // 30 seconds at 0.5 percent a minute: START * 1.005^0.5
        assertApproxEqRel(core.ethRate(), START * 1_002_496_882_788_171_067 / 1e18, 1e9, "and climbing");
    }

    /// a pot with under one credit of room for 10 hours does not raise the price state: the climb stops at the clamp, so a
    /// refill resumes from the price before the starvation
    function test_starvedPotDoesNotRaiseThePriceState() public {
        _potTo(20 ether);
        _sellOne();
        uint256 price = core.rateAtCheckpoint();
        // drain the pot to under one credit, then book 1 wei so that a checkpoint runs at the small pot
        stdstore.target(address(core)).sig("ethPot()").checked_write(uint256(1e15));
        vm.deal(address(core), 1e15 + 1);
        core.skim();
        assertEq(core.ethPot(), 1e15 + 1);
        assertEq(core.rateAtCheckpoint(), price, "the price state is not lowered by the small pot");
        _warp(10 hours);
        assertEq(core.ethRate(), core.ethPot(), "the read is the clamp of the small pot");
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        assertEq(core.rateAtCheckpoint(), price, "and a starved pot does not raise the price state");
        _potTo(20 ether);
        assertEq(core.rateAtCheckpoint(), price, "the checkpoint at the refill stores the price from before");
        assertEq(core.ethRate(), price, "the read after the refill is that price");
        _warp(10 minutes);
        // 1.005^10 = 1.0511401320407896
        assertApproxEqRel(core.ethRate(), price * 1_051_140_132_040_790_000 / 1e18, 1e9, "and it climbs from there");
    }

    /// starved to 0.0001 eth for a day and refilled to 0.0005 eth: the read is the clamp of 0.0005 eth, the first fill pays it
    /// and drops the price state from the opening rate. a refill to 1 eth reads the price state
    function test_partialRefillReadsTheClampAndTheFirstFillDropsFromTheOpeningRate() public {
        _potTo(0.0001 ether);
        _warp(24 hours);
        _potTo(0.0005 ether);
        uint256 clamp = 0.0005 ether;
        assertEq(core.ethRate(), clamp, "the clamp of 0.0005 eth");
        assertEq(core.rateAtCheckpoint(), START, "the price state waited at the opening rate");
        uint256 id = _credits(seller, 1)[0];
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(_one(id));
        assertEq(seller.balance - before, clamp, "the first fill pays the clamp");
        assertEq(core.rateAtCheckpoint(), START * 9_950 / 10_000, "and drops the opening rate by 0.5 percent");
        (uint256 anchor,,) = _anchor();
        assertEq(anchor, START, "the anchor is the opening rate");
        _potTo(1 ether);
        assertEq(core.ethRate(), START * 9_950 / 10_000, "with 1 eth in the pot the read is the price state");
    }

    /// a pot of 1.9 credits: the first fill pays the price state, the second pays the clamp of the rest, and the
    /// anchor stays the price state at each fill
    function test_hourEnd_clampedFillsKeepTheAnchor() public {
        _potTo(START * 19 / 10);
        uint256 price = START;
        for (uint256 i; i < 2; ++i) {
            uint256 pot = core.ethPot();
            uint256 clamp = pot;
            uint256 read = price < clamp ? price : clamp;
            assertEq(core.ethRate(), read);
            uint256 id = _credits(seller, 1)[0];
            uint256 before = seller.balance;
            vm.prank(seller);
            core.sellForEth(_one(id));
            assertEq(seller.balance - before, read, "paid the read");
            if (i > 0) assertLt(read, price, "the clamp binds from the second fill");
            (uint256 anchor,,) = _anchor();
            assertEq(anchor, price, "the anchor is the price state at the fill");
            price = price * 9_950 / 10_000;
            assertEq(core.rateAtCheckpoint(), price, "and the price state drops as at full price");
        }
    }

    /// a batch of three sold into a pot of 2.5 credits at the opening rate: the first two credits pay the price
    /// state, the third pays the clamp of the pot it finds, and the anchor is the price state at the third fill
    function test_clampBoundBatchPaysTheClampedReadAndAnchorsAtThePrice() public {
        uint256 pot = START * 5 / 2;
        _potTo(pot);
        assertEq(core.ethRate(), START);
        uint256[] memory ids = _credits(seller, 3);
        uint256 expected;
        uint256 price = START;
        for (uint256 i; i < 3; ++i) {
            uint256 clamp = pot;
            uint256 pay = price < clamp ? price : clamp;
            if (i == 2) assertLt(clamp, price, "the clamp binds at the third fill");
            expected += pay;
            pot -= pay;
            price = price * 9_950 / 10_000;
        }
        uint256 before = seller.balance;
        vm.prank(seller);
        core.sellForEth(ids);
        assertEq(seller.balance - before, expected, "the batch pays the price state twice and the clamp once");
        assertEq(core.ethPot(), pot);
        assertLt(expected, 3 * START, "the clamp binds");
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, _walk(START, 2, 50), "the anchor is the price state at the third fill");
        assertEq(start, START, "the minute started at the opening rate");
        assertEq(core.rateAtCheckpoint(), _walk(START, 3, 50), "and the price state dropped once per credit");
    }

    /// a fill in the minute of a `setRate` that lowered the rate below the floor of the minute still drops 0.5 percent
    function test_setRateLowerThenFillInTheSameMinuteDrops() public {
        _potTo(20 ether);
        _sellOne();
        (, uint256 start,) = _anchor();
        assertEq(start, START);
        vm.prank(owner);
        core.setRate(0.8e15);
        assertLt(0.8e15, START * 5_000 / 10_000, "below the floor of the minute");
        _sellOne();
        (uint256 anchor, uint256 start2,) = _anchor();
        assertEq(anchor, 0.8e15, "the anchor is the restated rate");
        assertEq(start2, 0.8e15, "the floor restarts at the restated rate");
        assertEq(core.rateAtCheckpoint(), 0.8e15 * 9_950 / 10_000, "the fill dropped 0.5 percent");
    }

    /// the owner lowers `ceilBps` below the stored rate: the read is the new ceiling
    function test_loweredCeilBpsBoundsTheRead() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(5 minutes);
        assertEq(core.ethRate(), anchor * 11_000 / 10_000);
        Settings memory s = core.settings();
        s.ceilBps = 10_000;
        _setSettings(s);
        assertEq(core.rateAtCheckpoint(), anchor * 11_000 / 10_000, "setSettings stores the rate it found");
        assertEq(core.ethRate(), anchor, "the new ceiling is 100 percent of the anchor");
    }

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

    /// `buyListing` is one fill: the rate drops once and the anchor is the bid rate at that moment, not the cost
    function test_buyListingIsOneFillAndTheAnchorIsTheBidRate() public {
        uint256 price = _forListing();
        uint256 rate = core.ethRate();
        vm.prank(keeper);
        core.buyListing(price, _listingData(LISTED_A), LISTED_A, STRATEGY);
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, rate, "the anchor is the bid rate");
        assertEq(start, rate);
        assertTrue(anchor != price, "not derived from the cost");
        assertEq(core.rateAtCheckpoint(), rate * 9_950 / 10_000, "one drop of 0.5 percent");
        assertEq(core.lastFillTime(), block.timestamp);
    }

    /// `buyListing` with the clamp binding: one fill, the cost basis is the cost plus the payment, the anchor is the price state
    /// at the fill and the price state drops once
    function test_buyListingAtTheClampIsOneFill() public {
        uint256 price = _forListing();
        _warpUntilCeiling(LISTED_A, price * 3);
        // store the price state, then leave a pot whose clamp is half of it
        vm.deal(address(core), address(core).balance + 1);
        core.skim();
        uint256 state = core.rateAtCheckpoint();
        uint256 pot = state / 2;
        stdstore.target(address(core)).sig("ethPot()").checked_write(pot);
        vm.deal(address(core), pot);
        assertEq(core.ethRate(), state / 2, "the clamp binds");
        uint256 ceiling = core.ethRate();
        assertGe(ceiling, price, "and the ceiling still covers the listing");
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        core.buyListing(price, _listingData(LISTED_A), LISTED_A, STRATEGY);
        uint256 paid = keeper.balance - keeperBefore;
        _assertListingPay(paid, ceiling - price);
        (,, uint256 basis,) = core.creditInfo(LISTED_A);
        assertEq(basis, price + paid, "the cost basis is the cost plus the payment");
        assertEq(core.ethPot(), pot - price - paid);
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(anchor, state, "the anchor is the price state at the fill");
        assertEq(start, state);
        assertEq(core.rateAtCheckpoint(), state * 9_950 / 10_000, "exactly one drop");
    }

    /// a reverted buy and a sell of no credit change neither the rate nor the anchor
    function test_revertedBuyAndEmptySellLeaveTheRateAndTheAnchor() public {
        uint256 price = _forListing();
        uint256 rate = core.rateAtCheckpoint();
        (uint256 a0, uint256 s0, uint256 b0) = _anchor();
        vm.prank(keeper);
        vm.expectRevert(ICore.CallFailed.selector);
        core.buyListing(price - 1, _listingData(LISTED_A), LISTED_A, STRATEGY);
        vm.prank(seller);
        vm.expectRevert(ICore.Empty.selector);
        core.sellForEth(new uint256[](0));
        vm.prank(seller);
        vm.expectRevert(ICore.ZeroId.selector);
        core.sellForEth(_one(0));
        (uint256 a1, uint256 s1, uint256 b1) = _anchor();
        assertEq(core.rateAtCheckpoint(), rate);
        assertTrue(a0 == a1 && s0 == s1 && b0 == b1, "the anchor state is unchanged");
    }

    /// a second fill in the minute bucket, after the climb took the rate above the first rate of the bucket: the floor
    /// still counts from the first rate, the anchor is the new rate paid
    function test_secondFillInTheBucketAfterTheClimbRaisedTheRate() public {
        _with(_fastClimb);
        _potTo(20 ether);
        _warp(1 hours);
        vm.warp((block.timestamp / 60 + 1) * 60 + 5);
        uint256[] memory ids = _credits(seller, 2);
        uint256 r0 = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(ids[0]));
        _warp(50);
        uint256 paid = core.ethRate();
        assertGt(paid, r0, "the climb took the rate above the first rate of the bucket");
        vm.prank(seller);
        core.sellForEth(_one(ids[1]));
        (uint256 anchor, uint256 start,) = _anchor();
        assertEq(start, r0, "the minute still starts at the first rate paid");
        assertEq(anchor, paid, "the anchor is the second rate paid");
        assertEq(
            core.rateAtCheckpoint(), paid * 9_950 / 10_000, "the floor of 50 percent of the first rate is not reached"
        );
    }

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

    /// `setSettings` keeps the anchor, the minute state and the fill clock
    function test_setSettingsKeepsTheAnchor() public {
        _potTo(20 ether);
        _sellOne();
        (uint256 a0, uint256 s0, uint256 b0) = _anchor();
        uint64 fillTime = core.lastFillTime();
        _warp(7 minutes);
        _with(_fastClimb);
        (uint256 a1, uint256 s1, uint256 b1) = _anchor();
        assertTrue(a0 == a1 && s0 == s1 && b0 == b1, "the anchor state is unchanged");
        assertEq(core.lastFillTime(), fillTime);
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

    /// the market price doubles between two fills. the cheapest seller asks 60 percent of the new price, 120 percent of
    /// the old one. the ceiling (110 percent of the anchor, grown 2 percent per 10 idle minutes) clears 120 percent at the
    /// fifth interval, so the bid reaches it in 50 minutes
    function test_gapUp100Percent_cheapestAskAt120PercentFillsWithinAnHour() public {
        (uint256 m, uint256 anchor) = _minutesToFirstFill(12_000);
        emit log_named_uint("minutes to the first fill after a +100 percent gap", m);
        assertGt(m, 0, "filled");
        assertLe(m, 60, "within an hour");
        assertLe(core.ethRate(), anchor * (10_000 + 200 * (m / 10)) * 11_000 / 1e8, "inside the ceiling");
        // the climb alone reaches 1.2 at minute 38 (0.995 * 1.005^m >= 1.2), the ceiling at minute 50
        assertEq(m, 50);
    }

    /// every seller asks the full new price, 200 percent of the old one: at the launch loosening the ceiling clears
    /// 200 percent at the 41st interval (110 percent * (1 + 2 percent * 41)), 410 minutes, a little under 7 hours. the
    /// climb alone would reach it at minute 139 (0.995 * 1.005^m >= 2)
    function test_gapUp100Percent_everyAskAtTheNewPriceWaitsForTheClimb() public {
        (uint256 m,) = _minutesToFirstFill(20_000);
        emit log_named_uint("minutes to the first fill, no cheap ask", m);
        assertEq(m, 410);
    }

    /// the lowest loosening the bounds allow (1 basis point per 10 idle minutes) still lifts the ceiling to 200 percent
    /// of the last rate paid: 110 percent * (1 + k / 10,000) reaches 200 percent at k = 8,182 intervals, 56.8 days
    function test_gapUp100Percent_withTheMinimumLooseningTheBidReachesDouble() public {
        _with(_minLoosening);
        _potTo(20 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        _warp(8_181 * 10 minutes);
        assertLt(core.ethRate(), anchor * 2, "interval 8,181");
        _warp(10 minutes);
        assertGe(core.ethRate(), anchor * 2, "interval 8,182");
    }

    /// zero loosening is outside the bounds: the setting that parked the bid at 110 percent of the last rate paid
    function test_zeroLooseningIsRefused() public {
        Settings memory s = core.settings();
        s.idleLoosenBps = 0;
        _expectBad(s, "idleLoosenBps");
    }
}
