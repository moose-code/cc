// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Settings} from "../src/interfaces/Interfaces.sol";
import {RateStore} from "../src/lib/RateStore.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice an independent oracle for the dual speed recovery climb (CoreLib._recover): a small step simulation of the
/// rule "fast below the recovery level, slow at or above it", where the recovery level is `recoveryGapBps` under the
/// decaying peak. the closed form crossing is validated against the simulation at the launch settings and with a
/// recovery rate above the climb rate and a non zero gap. the model BidModel copies the closed form, so it cannot
/// catch a wrong crossing; this simulation does not read the closed form and can
contract RecoveryOracleTest is Fixture {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
        _skipSniperWindow();
        _fundPot(1 ether);
    }

    /// @dev writes the rate checkpoint, the fill clock and the four anchor words directly, and funds the pot. the slot
    /// numbers are the Core state layout (rateAtCheckpoint 10, checkpointTime|lastFillTime 11, ethPot 6) and the
    /// RateStore anchor words
    function _storeState(
        uint256 r,
        uint256 cp,
        uint256 lastFill,
        uint256 lastFillRate,
        uint256 peakRate,
        uint256 peakTime,
        uint256 pot
    ) internal {
        vm.store(address(core), bytes32(uint256(10)), bytes32(r));
        vm.store(address(core), bytes32(uint256(11)), bytes32(cp | (lastFill << 64)));
        bytes32 slot = RateStore.SLOT;
        vm.store(address(core), slot, bytes32(lastFillRate));
        uint256 w2 = uint256(vm.load(address(core), bytes32(uint256(slot) + 2)));
        w2 = (w2 & type(uint64).max) | (peakTime << 64);
        vm.store(address(core), bytes32(uint256(slot) + 2), bytes32(w2));
        vm.store(address(core), bytes32(uint256(slot) + 3), bytes32(peakRate));
        vm.store(address(core), bytes32(uint256(6)), bytes32(pot));
        vm.deal(address(core), pot + core.ethToBuyback());
    }

    /// @dev the remembered peak decayed over `age` seconds, by the halving the library uses
    function _peakAt(Settings memory s, uint256 stored, uint256 age) internal pure returns (uint256) {
        uint256 halvings = age / s.peakHalfLife;
        uint256 v = stored >> halvings;
        uint256 rest = age % s.peakHalfLife;
        if (rest != 0) v = v * uint256(FixedPointMathLib.powWad(0.5e18, int256(rest * 1e18 / s.peakHalfLife))) / 1e18;
        return v;
    }

    /// @dev the price state from an independent step simulation with `sub` substeps a second: each substep the state
    /// climbs at the fast rate while it is below the recovery level `peakNow * (10_000 - recoveryGapBps) / 10_000` and
    /// at the slow rate at or above it, the peak decaying over the substep, all clamped to `target`. a finer grid
    /// (larger `sub`) leaves less discretisation against the continuous closed form
    function _stepSim(Settings memory s, uint256 r, uint256 pk, uint256 elapsed, uint256 target, uint256 sub)
        internal
        pure
        returns (uint256 p)
    {
        int256 per = int256(60 * sub);
        uint256 gf = uint256(FixedPointMathLib.expWad(FixedPointMathLib.lnWad(int256(1e18 + uint256(s.recoveryClimbPerMinBps) * 1e14)) / per));
        uint256 gs = uint256(FixedPointMathLib.expWad(FixedPointMathLib.lnWad(int256(1e18 + uint256(s.climbPerMinBps) * 1e14)) / per));
        uint256 d = uint256(FixedPointMathLib.expWad(-FixedPointMathLib.lnWad(2e18) / int256(uint256(s.peakHalfLife) * sub)));
        uint256 gap = 10_000 - s.recoveryGapBps;
        p = r;
        elapsed *= sub;
        for (uint256 i; i < elapsed; ++i) {
            p = p.mulWad(p < pk * gap / 10_000 ? gf : gs);
            if (p > target) p = target;
            pk = pk.mulWad(d);
        }
    }

    /// the closed form against the step simulation over random recovery, climb, half life and gap, with the peak above
    /// the price state and a high ceiling and rate cap so the unclamped climb is what is compared
    function testFuzz_closedFormMatchesStepSim(uint256 seed, uint256 k, uint256 elapsed, uint256 peakAge) public {
        Settings memory s = core.settings();
        s.climbPerMinBps = uint16(bound(seed, 1, 1_000));
        s.recoveryClimbPerMinBps = uint16(bound(seed >> 16, s.climbPerMinBps, 1_000));
        s.peakHalfLife = uint32(bound(seed >> 32, 600, 604_800));
        s.recoveryGapBps = uint16(bound(seed >> 64, 0, 5_000));
        s.ceilBps = 30_000;
        s.rateCap = 1e18;
        _setSettings(s);
        uint256 r = 1e15;
        uint256 peakT = r * bound(k, 1001, 20_000) / 1000;
        uint256 age = bound(peakAge, 0, 2 days);
        elapsed = bound(elapsed, 1, 3 hours);
        uint256 now0 = block.timestamp;
        _storeState(r, now0, now0, 3e17, peakT, now0 - age, 1_000_000 ether);
        uint256 pk = _peakAt(s, peakT, age);
        vm.warp(now0 + elapsed);
        uint256 got = core.ethPrice();
        uint256 sim = _stepSim(s, r, pk, elapsed, 9e17, 1);
        if (sim >= 9e17) assertGe(got, 9e17, "clamped at the ceiling");
        else assertApproxEqRel(got, sim, 0.003e18, "closed form vs step simulation");
    }

    /// the launch settings (recovery 200, climb 50, half life 6 h, gap 200): the closed form matches a tenth of a
    /// second step simulation within 50 ppm over a range of elapsed times, well past the crossing
    function test_closedFormLaunchErr() public {
        uint256[6] memory el = [uint256(60), 600, 1800, 2700, 3600, 7200];
        Settings memory s = core.settings();
        s.ceilBps = 30_000;
        s.rateCap = uint64(1e18);
        _setSettings(s);
        s = core.settings();
        for (uint256 j; j < 6; ++j) {
            uint256 snap = vm.snapshotState();
            uint256 now0 = block.timestamp;
            uint256 r = 1e15;
            uint256 peakT = 4e15;
            _storeState(r, now0, now0, 3e17, peakT, now0, 1_000_000 ether);
            vm.warp(now0 + el[j]);
            uint256 got = core.ethPrice();
            uint256 sim = _stepSim(s, r, peakT, el[j], 1e18, 10);
            uint256 ppm = got > sim ? (got - sim) * 1e6 / sim : (sim - got) * 1e6 / sim;
            emit log_named_uint("elapsed", el[j]);
            emit log_named_uint("err ppm (closed form vs step sim)", ppm);
            assertLe(ppm, 50, "closed form within 50 ppm of the step simulation at launch settings");
            vm.revertToState(snap);
        }
    }

    /// the recovery level is at or below the price state (the fill sits inside the gap of the peak), so `_recover`
    /// takes the `levelT <= r` branch and climbs at the slow rate only. the step simulation agrees
    function test_recoverSlowWhenLevelAtOrBelowRate() public {
        Settings memory s = core.settings();
        s.ceilBps = 30_000;
        s.rateCap = uint64(1e18);
        _setSettings(s);
        s = core.settings();
        uint256 now0 = block.timestamp;
        uint256 r = 1e15;
        uint256 peakT = 1e15; // levelT = peakT * (10_000 - 200) / 10_000 < r
        _storeState(r, now0, now0, 3e17, peakT, now0, 1_000_000 ether);
        vm.warp(now0 + 1800);
        uint256 got = core.ethPrice();
        uint256 sim = _stepSim(s, r, peakT, 1800, 1e24, 10);
        assertGt(got, r, "the price state climbed");
        assertApproxEqRel(got, sim, 0.003e18, "slow climb when the level is at or below the rate");
    }

    /// the recovery level is above a low target (the pot bounds the climb) and enough time passes that the fast leg
    /// reaches the target before the crossing, so `_recover` takes the `priceCross >= target` branch and returns the
    /// target. the step simulation clamps to the same value
    function test_recoverClampsAtTargetThroughTheFastLeg() public {
        Settings memory s = core.settings();
        s.ceilBps = 30_000;
        s.rateCap = uint64(1e18);
        _setSettings(s);
        s = core.settings();
        uint256 now0 = block.timestamp;
        uint256 r = 1e15;
        uint256 peakT = 20e15; // levelT = 19.6e15, far above the pot bound
        uint256 pot = 2e15; // target = cap.min(pot) = pot, below the level
        _storeState(r, now0, now0, 1e15, peakT, now0, pot);
        vm.warp(now0 + 3 hours);
        uint256 got = core.ethPrice();
        assertEq(got, pot, "the price state clamps at the target through the fast leg");
        uint256 sim = _stepSim(s, r, peakT, 3 hours, pot, 10);
        assertApproxEqRel(got, sim, 0.003e18, "closed form matches the step simulation at the clamp");
    }
}
