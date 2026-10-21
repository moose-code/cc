// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiveFixture} from "./utils/LiveFixture.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {Halving} from "../src/lib/Halving.sol";
import {BidModel} from "./utils/BidModel.sol";

/// @notice decision 74: after a large sale walks the bid down, the remembered peak keeps the ceiling high and the price
/// state climbs back at the recovery rate. these scenarios run against the live core under its live settings (the live
/// recoveryClimbPerMinBps is 100, not the shipped decision 155 value of 200). the recovery time is no longer the pinned
/// launch count; each dump test recomputes its expected recovery minutes from the live core state through BidModel, the
/// same model test_recoveryAndPeakHalvingAtLaunchDrop validates, so the promise is measured at whatever the live climb is
contract RecoveryTest is LiveFixture {
    address internal seller_;

    function setUp() public override {
        super.setUp();
        seller_ = seller;
        // the recovery mechanism is read against a 5 percent drop and a 50 percent minute floor; the live core runs no
        // practical floor (dropFloorBps 1), so set the floor and drop the recovery tests read against. the climb is left
        // at the live value
        Settings memory s = core.settings();
        s.dropPer100PointsBps = 500;
        s.dropFloorBps = 5_000;
        _setSettings(s);
        _skipSniperWindow();
        // the live credits score well above 100 points, so each fill bids several times the per 100 point rate; fund the
        // pot past the batch dump. the recovery climb is unscaled by the pot (decision 128 variant d), so this does not
        // move the measured minute counts
        _fundPot(5 ether);
    }

    /// @dev the whole minutes until the price state climbs back to `target`, projected through BidModel from the live
    /// core state now (between fills the price is a pure function of elapsed time, so this needs no warp). this is the
    /// live-settings expectation the measured recovery is checked against, replacing the decision 155 launch count
    function _modelMinutesToRecover(uint256 target) internal view returns (uint256) {
        Settings memory s = core.settings();
        BidModel.Bid memory b = _modelBid();
        uint256 t0 = block.timestamp;
        for (uint256 m = 1; m <= 600; ++m) {
            b.nowTs = t0 + m * 1 minutes;
            if (BidModel.priceNow(s, b) >= target) return m;
        }
        return type(uint256).max;
    }

    // promise: SPEC 1 the recovery settings (recoveryGapBps, recoveryClimbPerMinBps)
    /// read against the live core. the recovery gap is the shipped 1,000. FINDING: the live climb is 100, while the
    /// shipped mainnet.json and decision 155 value is 200; the live configuration was tuned down after launch, so the
    /// decision 155 recovery-speed calibration no longer holds. the dump tests measure the recovery at the live climb
    function test_liveRecoverySettings() public view {
        string memory json = vm.readFile("script/config/mainnet.json");
        assertEq(vm.parseJsonUint(json, ".settings.recoveryGapBps"), 1_000, "shipped config gap");
        assertEq(vm.parseJsonUint(json, ".settings.recoveryClimbPerMinBps"), 200, "shipped config climb");
        assertEq(core.settings().recoveryGapBps, 1_000, "the live core keeps the shipped recovery gap");
        assertEq(
            core.settings().recoveryClimbPerMinBps,
            100,
            "the live core runs recoveryClimbPerMinBps 100, not the shipped 200"
        );
    }

    /// @dev sells `n` credits within the current block (one minute bucket), so the minute floor binds. the live credits
    /// carry their real scores, so each fill drops the rate by `dropPer100PointsBps * score / RATE_SCORE`; a batch this
    /// size overshoots the 50 percent minute floor either way, and the per point scaling is covered by the invariant suite
    function _dump(uint256 n) internal {
        uint256[] memory ids = _credits(seller_, n);
        for (uint256 i; i < n; ++i) {
            vm.prank(seller_);
            core.sellForEth(_one(ids[i]));
        }
    }

    /// @dev the whole minutes until the price state climbs back to `target`, warping one minute at a time
    function _minutesToRecover(uint256 target) internal returns (uint256) {
        for (uint256 m = 1; m <= 600; ++m) {
            _warp(1 minutes);
            if (core.ethPrice() >= target) return m;
        }
        return type(uint256).max;
    }

    // promise: SPEC 1 after a large sale the bid recovers fast (peak anchor)
    /// a one minute dump of 140 credits drops the bid to the 50 percent minute floor; the remembered peak then brings it
    /// back to the pre dump price. the recovery time is read at the live climb from BidModel rather than the decision 155
    /// launch count, and the measured recovery matches that model. the climb is unscaled by the pot (decision 128 variant d)
    function test_oneMinuteDumpRecovers() public {
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        uint256 pre = core.ethPrice();
        assertEq(pre, OPEN_RATE, "pre dump price is the opening bid");
        _dump(140);
        uint256 dropped = core.ethPrice();
        assertLt(dropped, pre * 55 / 100, "the dump cut the bid to about the 50 percent minute floor");
        assertGe(dropped, pre * 45 / 100, "the dump did not fall below the minute floor");
        uint256 expected = _modelMinutesToRecover(pre);
        assertLt(
            expected, type(uint256).max, "the peak anchor recovers the bid to the pre dump price at the live climb"
        );
        uint256 m = _minutesToRecover(pre);
        emit log_named_uint("one minute dump: minutes to recover to the pre dump price", m);
        assertEq(m, expected, "the measured recovery matches the live-settings model");
    }

    // promise: SPEC 1 after a large sale the bid recovers fast (peak anchor)
    /// a three minute dump of about 420 credits walks the bid down by half each minute, to about an eighth of the pre
    /// dump price; the remembered peak brings it back. the recovery time is read at the live climb from BidModel rather
    /// than the decision 155 launch count, and the measured recovery matches that model (the climb is unscaled by the pot)
    function test_threeMinuteDumpRecovers() public {
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        uint256 pre = core.ethPrice();
        for (uint256 i; i < 3; ++i) {
            _dump(140);
            if (i < 2) _warp(1 minutes);
        }
        uint256 dropped = core.ethPrice();
        assertLt(dropped, pre * 20 / 100, "three minutes of dumping cut the bid to about an eighth");
        uint256 expected = _modelMinutesToRecover(pre);
        assertLt(
            expected, type(uint256).max, "the peak anchor recovers the bid to the pre dump price at the live climb"
        );
        uint256 m = _minutesToRecover(pre);
        emit log_named_uint("three minute dump: minutes to recover to the pre dump price", m);
        assertEq(m, expected, "the measured recovery matches the live-settings model");
    }

    // promise: SPEC 1 setRate restates the remembered peak
    /// `setRate` restates the remembered peak and its time, so a later climb treats the restated rate as the peak
    function test_setRateRestatesThePeak() public {
        _dump(40);
        (uint256 peakBefore,) = _peak();
        vm.prank(owner);
        core.setRate(OPEN_RATE * 2);
        (uint256 peakRate, uint256 peakTime) = _peak();
        assertEq(peakRate, OPEN_RATE * 2, "the peak is the restated rate");
        assertEq(peakTime, block.timestamp, "the peak time is now");
        assertTrue(peakRate != peakBefore, "the peak moved");
        // the price state is the restated rate and is at or above the peak, so a climb from here is the slow rate
        assertEq(core.ethPrice(), OPEN_RATE * 2, "the price state is the restated rate");
    }

    // promise: SPEC 1 a peakHalfLife change checkpoints the peak first
    /// a change of `peakHalfLife` restates the remembered peak at the old half life first, so the elapsed decay is not
    /// rescaled: the peak now is unchanged across the setting change, `peakTime` is reset to now, and the new half life
    /// decays it forward. without the restatement the old stored peak would read far higher under a longer half life
    function test_setSettingsChangingHalfLifeCheckpointsThePeak() public {
        vm.prank(owner);
        core.setRate(OPEN_RATE * 2);
        (uint256 peakBefore,) = _peak();
        _warp(3 hours);
        uint256 expected = Halving.halve(peakBefore, 3 hours, 21_600);
        Settings memory s = core.settings();
        s.peakHalfLife = 604_800; // 7 days
        _setSettings(s);
        (uint256 peakRate, uint256 peakTime) = _peak();
        assertApproxEqRel(
            peakRate, expected, 1e-9 ether, "the peak is restated at the old half life, so it is unchanged now"
        );
        assertEq(peakTime, block.timestamp, "the peak time is reset to now");
        assertLt(peakRate, peakBefore, "the restated peak is below the stored peak (it had decayed)");
    }

    /// the price state now from the core's checkpoint, anchor and peak, read the way HandlerBase builds the model
    function _modelBid() internal view returns (BidModel.Bid memory) {
        (uint256 anchor,,) = _anchor();
        (uint256 peakRate, uint256 peakTime) = _peak();
        return BidModel.Bid({
            r: core.rateAtCheckpoint(),
            pot: core.ethPot(),
            pagesPot: core.ethPot(),
            lastFillRate: anchor,
            peakRate: peakRate,
            peakTime: peakTime,
            lastFillTime: core.lastFillTime(),
            checkpointTime: core.checkpointTime(),
            nowTs: block.timestamp
        });
    }

    // promise: SPEC 1 the recovery climb and the peak halving match the model at the launch drop (115 bps, floor 1)
    /// RecoveryTest.setUp calibrates with a 5 percent drop and a 50 percent minute floor; this case resets them to the
    /// shipped launch values and checks the recovery after an 80 credit dump against BidModel at 6, 12 and 24 hours. the
    /// model folds in the recovery climb and the remembered peak halving at the launch half life, so a match validates
    /// both at launch
    function test_recoveryAndPeakHalvingAtLaunchDrop() public {
        Settings memory s = core.settings();
        s.dropPer100PointsBps = 115;
        s.dropFloorBps = 1;
        _setSettings(s);
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        uint256 pre = core.ethPrice();
        assertEq(pre, OPEN_RATE, "pre dump price is the opening bid");
        _dump(80);
        assertLt(core.ethPrice(), pre, "the 80 credit dump walked the price state down at the launch drop");
        (uint256 peakRate,) = _peak();
        assertEq(peakRate, pre, "the remembered peak is the pre dump rate");

        uint256 t0 = block.timestamp;
        uint256[3] memory ages = [uint256(6 hours), 12 hours, 24 hours];
        for (uint256 i; i < ages.length; ++i) {
            vm.warp(t0 + ages[i]);
            Settings memory sn = core.settings();
            assertEq(core.ethPrice(), BidModel.priceNow(sn, _modelBid()), "the price state follows the model");
            assertEq(
                core.ethRate(),
                BidModel.read(sn, core.ethPot(), BidModel.priceNow(sn, _modelBid())),
                "the read follows the model clamped to the pot"
            );
        }
    }

    // promise: inv 6 the price state follows the model between fills
    /// the lazy climb is monotone in time between fills. the raw climb trajectory never falls: with a high ceiling, the
    /// longest peak half life (so the ceiling anchor barely decays over the window) and a large pot, neither the ceiling
    /// nor the clamp binds, so the price state is the raw climb and a later read is never below an earlier one, whatever
    /// the dump that preceded it. the climb is unscaled by the pot multiplier (decision 128 variant d), so the raw climb
    /// is the launch rate and stays below the high ceiling over the window. the clamped price following a decaying cap
    /// down is the intended behaviour and is not tested here
    /// forge-config: default.fuzz.runs = 40
    function testFuzz_priceStateMonotoneBetweenFills(uint256 dumpSeed, uint256 recovSeed) public {
        Settings memory s = core.settings();
        s.ceilBps = 30_000;
        s.rateCap = uint64(1e18);
        s.recoveryClimbPerMinBps = uint16(bound(recovSeed, s.climbPerMinBps, 1_000));
        s.peakHalfLife = 604_800;
        _setSettings(s);
        _fundPot(50 ether);
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        uint256 dump = bound(dumpSeed, 1, 200);
        _dump(dump);
        uint256 prev = core.ethPrice();
        for (uint256 i; i < 40; ++i) {
            _warp(bound(uint256(keccak256(abi.encode(recovSeed, i))), 1, 3 minutes));
            uint256 now_ = core.ethPrice();
            assertGe(now_ + now_ / 1e9, prev, "the price state climbs monotonically between fills");
            prev = now_;
        }
    }
}
