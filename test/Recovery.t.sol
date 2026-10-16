// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Settings, Mainnet} from "../src/interfaces/Interfaces.sol";
import {Halving} from "../src/lib/Halving.sol";

/// @notice decision 74: after a large sale walks the bid down, the remembered peak keeps the ceiling high and the price
/// state climbs back at the recovery rate. these scenarios measure the recovery time at the launch settings and the
/// overshoot after a market fall, and check that `setRate` restates the peak and the climb is monotone between fills.
contract RecoveryTest is Fixture {
    address internal seller_;

    // promise: SPEC 1 the recovery settings at launch (recoveryGapBps, peakHalfLife)
    /// the launch values these tests measure. the config file, `Mainnet.defaultSettings()` and the fixture core agree, and
    /// the dump recoveries and the batch seller rates are pinned at this gap, so a change of the launch gap changes them.
    /// the lone seller and market fall values do not depend on the gap
    function test_launchGapIs1000() public view {
        string memory json = vm.readFile("script/config/mainnet.json");
        assertEq(vm.parseJsonUint(json, ".settings.recoveryGapBps"), 1_000, "shipped config");
        assertEq(vm.parseJsonUint(json, ".settings.recoveryClimbPerMinBps"), 100, "shipped config climb");
        assertEq(Mainnet.defaultSettings().recoveryGapBps, 1_000, "defaultSettings");
        assertEq(core.settings().recoveryGapBps, 1_000, "fixture core");
        assertEq(core.settings().recoveryClimbPerMinBps, 100, "fixture core climb");
    }

    function setUp() public override {
        super.setUp();
        seller_ = seller;
        // the recovery mechanism is calibrated with a 5 percent drop and a 50 percent minute floor; the launch runs no
        // practical floor (dropFloorBps 1, decision 146), so set the floor and drop the recovery tests read against
        Settings memory s = core.settings();
        s.dropPer100PointsBps = 500;
        s.dropFloorBps = 5_000;
        _setSettings(s);
        _skipSniperWindow();
        _fundPot(1 ether);
    }

    /// @dev sells `n` credits within the current block (one minute bucket), so the minute floor binds. each credit has
    /// `refScore` set to its score, so the eth bid pays the full rate and the fill drops the rate by the full
    /// dropPer100PointsBps (score / refScore is 1); the per-point scaling is covered by the invariant suite
    function _dump(uint256 n) internal {
        uint256[] memory ids = _credits(seller_, n);
        for (uint256 i; i < n; ++i) {
            _unitScore(ids[i]);
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
    /// a one minute dump of 140 credits halves the bid; the recovery climb brings it back to the pre dump price in about
    /// 70 minutes at the launch gap. at launch `climbPerMinBps` and `recoveryClimbPerMinBps` are both 100 (decision 151),
    /// so the climb from the 50 percent floor to the peak is a uniform 1 percent a minute. the climb is unscaled by the pot (decision
    /// 128 variant d scales only the ceiling loosening). the exact minute is asserted and logged
    function test_oneMinuteDumpRecovers() public {
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        uint256 pre = core.ethPrice();
        assertEq(pre, OPEN_RATE, "pre dump price is the opening bid");
        _dump(140);
        uint256 dropped = core.ethPrice();
        assertLt(dropped, pre * 55 / 100, "the dump cut the bid to about the 50 percent minute floor");
        assertGe(dropped, pre * 45 / 100, "the dump did not fall below the minute floor");
        uint256 m = _minutesToRecover(pre);
        emit log_named_uint("one minute dump: minutes to recover to the pre dump price", m);
        assertEq(m, 70, "one minute dump: minutes to recover at the launch gap");
    }

    // promise: SPEC 1 after a large sale the bid recovers fast (peak anchor)
    /// a three minute dump of about 420 credits walks the bid down by half each minute, to about an eighth of the pre
    /// dump price; the recovery climb brings it back in 207 minutes at the launch gap (the climb is unscaled by the pot)
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
        uint256 m = _minutesToRecover(pre);
        emit log_named_uint("three minute dump: minutes to recover to the pre dump price", m);
        assertEq(m, 207, "three minute dump: minutes to recover at the launch gap");
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
