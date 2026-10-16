// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {BidModel} from "./utils/BidModel.sol";
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

    /// sells one credit with `refScore` set to its score, so the eth bid pays the full rate (score / refScore is 1) and
    /// the drop is exactly `dropPerCreditBps`. the scaled bid and scaled drop at ratios other than 1 are in
    /// test/PerPointExact.t.sol
    function _sellOne() internal returns (uint256 price) {
        uint256 id = _credits(seller, 1)[0];
        _refScoreToCredit(id);
        price = core.ethRate();
        vm.prank(seller);
        core.sellForEth(_one(id));
    }

    // ------------------------------------------------------------------ drop

    // promise: SPEC 1 the bid rule: a fill drops the price state by dropPerCreditBps
    function test_oneFillDropsFivePercent() public {
        _potTo(10 ether);
        uint256 r0 = core.ethRate();
        assertEq(r0, START);
        uint256 price = _sellOne();
        assertEq(price, r0, "the rate before the fill");
        assertEq(core.rateAtCheckpoint(), r0 * 9_500 / 10_000, "5 percent below the rate paid");
        (uint256 anchor, uint256 start, uint256 bucket) = _anchor();
        assertEq(anchor, r0, "the rate paid is the anchor");
        assertEq(start, r0, "and the start of the minute");
        assertEq(bucket, block.timestamp / 60);
        assertEq(core.lastFillTime(), block.timestamp);
    }

    // promise: SPEC 1 the bid rule at launch: dropFloorBps 5_000 bounds the drop inside a minute
    /// at the launch drop of 5 percent the floor of 50 percent is reached on the 14th fill in one minute (0.95^13 is
    /// above 0.5, 0.95^14 is below it, so the 14th fill clamps to the floor)
    function test_launchDropReachesTheFloorOnTheFourteenthFill() public {
        _potTo(40 ether);
        uint256 r0 = core.ethRate();
        uint256[] memory ids = _credits(seller, 14);
        for (uint256 i; i < ids.length; ++i) {
            // each credit drops the rate by the full dropPerCreditBps: refScore set to its score (score / refScore is 1)
            _refScoreToCredit(ids[i]);
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
        assertEq(core.rateAtCheckpoint(), r0 * 9_500 / 10_000, "stored until the next checkpoint");
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
        // a pot under one page keeps the multiplier at 1x, so the loosening is the base 6 percent per 10 minutes
        _potTo(0.1 ether);
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
        s.dropPerCreditBps = 10_001;
        _expectBad(s, "dropPerCreditBps");
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
        // the climb is unscaled (climbPerMinBps 200): 1.02 per minute, 1.02^10 = 1.2189944199947573
        assertApproxEqRel(core.ethRate(), price * 1_218_994_419_994_757_376 / 1e18, 1e9, "and it climbs from there");
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
        // refScore set to the listed credit's score, so its bid is the full rate and the fill drops the rate by dropPerCreditBps
        _refScoreToCredit(LISTED_A);
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
        assertEq(core.rateAtCheckpoint(), rate * 9_500 / 10_000, "one drop of 5 percent");
        assertEq(core.lastFillTime(), block.timestamp);
    }

    // promise: SPEC 1 setRate restores the bid at once
    /// `setRate` restates the price: the stored rate and the ceiling anchor are both the new rate, the fill clock and
    /// the minute start stay
    function test_setRateRestatesTheRateAndTheAnchorAndKeepsTheFillClock() public {
        _with(_twoPercentLoosening);
        // a pot under one page keeps the multiplier at 1x, so the ceiling loosens at the base 2 percent per 10 minutes
        _potTo(0.1 ether);
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
    /// every seller asks the full new price, 200 percent of the old one. the 20 eth pot loosens the ceiling at the 4x
    /// cap, so the ceiling clears 200 percent within minutes, but the per minute climb is unscaled (decision 128 variant
    /// d, climbPerMinBps 200): the bid reaches 200 percent only when the 2 percent a minute climb gets there, minute 40
    function test_gapUp100Percent_everyAskAtTheNewPriceWaitsForTheClimb() public {
        (uint256 m,) = _minutesToFirstFill(20_000);
        emit log_named_uint("minutes to the first fill, no cheap ask", m);
        assertEq(m, 40);
    }

    // ------------------------------------------------------------------ decision 128: pot scaled climb

    function _highCeiling(Settings memory s) internal pure {
        s.ceilBps = 30_000;
    }

    /// @dev one minute of idle climb at a pot sized to `pages` pages (one page is 80 refScore credits at the stored
    /// rate). returns the realized per minute growth in bps over the stored rate, 10_000 being 1x. the pot override
    /// sets the multiplier to `clamp(pages, 1, 4)` exactly; a high ceiling keeps the one minute climb off the ceiling
    function _climbFactorBps(uint256 pages) internal returns (uint256) {
        _potTo(1 ether);
        _sellOne();
        (uint256 anchor,,) = _anchor();
        uint256 stored = core.rateAtCheckpoint();
        // the multiplier reads the last fill rate (the anchor), so pages of 80 at the anchor sets it to `pages` exactly
        uint256 pot = pages * 80 * anchor;
        stdstore.target(address(core)).sig("ethPot()").checked_write(pot);
        vm.deal(address(core), pot);
        _warp(60);
        return core.ethPrice() * 10_000 / stored;
    }

    // promise: SPEC 4 decision 128 variant d: the per minute climb does not scale with the pot, only the loosening does
    /// the climb is the launch rate (climbPerMinBps 200, 2 percent a minute) at one, three and ten pages alike
    function test_climbUnscaledByPotPages() public {
        _with(_highCeiling);
        assertApproxEqAbs(_climbFactorBps(1), 10_200, 2, "one page climbs at 1x");
        assertApproxEqAbs(_climbFactorBps(3), 10_200, 2, "three pages climb at the same 1x");
        assertApproxEqAbs(_climbFactorBps(10), 10_200, 2, "ten pages climb at the same 1x");
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
        // pages of 80 at the last fill rate (the anchor the multiplier reads) sets the multiplier to `pages` exactly
        uint256 pot = pages * 80 * anchor;
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
        _potTo(0.1 ether);
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

    // promise: an expired bucket's cleared anchor starts a fresh drop floor on its first fill
    function test_modelRestartsClearedDropAnchor() public pure {
        Settings memory s = Mainnet.defaultSettings();
        s.dropPerCreditBps = 10_000;
        s.dropFloorBps = 5_000;
        uint256 start = BidModel.startAfter(s, 1_000, 0);
        assertEq(start, 1_000);
        assertEq(BidModel.dropOnce(s, 1_000, start, s.refScore, s.refScore), 500);
    }
}
