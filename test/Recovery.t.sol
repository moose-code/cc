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

    /// the launch values these tests measure. the config file, `Mainnet.defaultSettings()` and the fixture core agree, and
    /// every measured value below is pinned at this gap, so a change of the launch gap changes them
    function test_launchGapIs1000() public view {
        string memory json = vm.readFile("script/config/mainnet.json");
        assertEq(vm.parseJsonUint(json, ".settings.recoveryGapBps"), 1_000, "shipped config");
        assertEq(vm.parseJsonUint(json, ".settings.recoveryClimbPerMinBps"), 200, "shipped config climb");
        assertEq(Mainnet.defaultSettings().recoveryGapBps, 1_000, "defaultSettings");
        assertEq(core.settings().recoveryGapBps, 1_000, "fixture core");
        assertEq(core.settings().recoveryClimbPerMinBps, 200, "fixture core climb");
    }

    function setUp() public override {
        super.setUp();
        seller_ = seller;
        _skipSniperWindow();
        _fundPot(1 ether);
    }

    /// @dev sells `n` credits in chunks within the current block (one minute bucket), so the minute floor binds
    function _dump(uint256 n) internal {
        while (n != 0) {
            uint256 k = n > 60 ? 60 : n;
            uint256[] memory ids = _credits(seller_, k);
            vm.prank(seller_);
            core.sellForEth(ids);
            n -= k;
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

    /// a one minute dump of 140 credits halves the bid; the recovery climb brings it back to the pre dump price in about
    /// 59 minutes at the launch gap (fast from the 50 percent floor up to the recovery level, then the slow climb over
    /// the last `recoveryGapBps` to the peak). the exact minute is asserted and logged
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
        assertEq(m, 59, "one minute dump: minutes to recover at the launch gap");
    }

    /// a three minute dump of about 420 credits walks the bid down by half each minute, to about an eighth of the pre
    /// dump price; the recovery climb brings it back in 146 minutes at the launch gap
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
        assertEq(m, 146, "three minute dump: minutes to recover at the launch gap");
    }

    /// a real market fall: the seller keeps filling at the new lower price, so the peak decays and the bid follows the
    /// market down. the overshoot above the market within the keeper's 3 minute window is bounded (decision 74: about 6
    /// percent). the overshoot is the most the price state sits above the latest fill price over the 3 minutes after it
    function test_marketFallOvershootBounded() public {
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        // the market falls: each step a batch of 15 credits drops the bid 7.2 percent, then nobody sells for 3 minutes
        // (the keeper window). the overshoot over the fill price is bounded by 3 minutes of the recovery climb
        // (6.12 percent at 2 percent a minute)
        uint256 overshoot;
        uint256 last = OPEN_RATE;
        for (uint256 step; step < 10; ++step) {
            _dump(15);
            last = core.ethPrice();
            // over the next 3 minutes the price state climbs; record how far above the fill price it reaches
            for (uint256 s = 1; s <= 3; ++s) {
                _warp(1 minutes);
                uint256 p = core.ethPrice();
                if (p > last) {
                    uint256 over = (p - last) * 10_000 / last;
                    if (over > overshoot) overshoot = over;
                }
            }
        }
        emit log_named_uint("market fall overshoot over the fill price, bps", overshoot);
        assertEq(overshoot, 612, "market fall overshoot over the fill price within 3 minutes, bps, at the launch gap");
    }

    /// @dev a seller of `k` credits per sale over one hour: whenever the read is at least the opening price, sells `k`
    /// credits in one call. polled every 3 seconds, 400 credit supply, 5 eth pot
    function _batchSeller(uint256 k) internal returns (uint256 sold, uint256 paid) {
        _fundPot(5 ether);
        vm.prank(owner);
        core.setRate(OPEN_RATE);
        uint256[] memory ids = _credits(seller_, 400);
        for (uint256 t; t < 1 hours; t += 3) {
            if (core.ethRate() >= OPEN_RATE) {
                uint256[] memory batch = new uint256[](k);
                for (uint256 j; j < k; ++j) {
                    batch[j] = ids[sold + j];
                }
                uint256 b = seller_.balance;
                vm.prank(seller_);
                core.sellForEth(batch);
                paid += seller_.balance - b;
                sold += k;
            }
            _warp(3);
        }
    }

    function _logBatch(uint256 k, uint256 sold, uint256 paid) internal {
        emit log_named_uint(string.concat("batches of ", vm.toString(k), " at launch gap: credits sold at >= opening price in 1h"), sold);
        emit log_named_uint(string.concat("batches of ", vm.toString(k), " at launch gap: wei paid"), paid);
    }

    /// a lone seller of one credit at a time: the single credit drop of 0.5 percent stays inside the launch gap, so the
    /// bid climbs at `climbPerMinBps` and the throughput is the slow climb's (the ungapped recovery climb gives 188)
    function test_loneSellerFlatPriceThroughput() public {
        (uint256 sold, uint256 paid) = _batchSeller(1);
        _logBatch(1, sold, paid);
        assertEq(sold, 60, "batches of 1: credits an hour at the opening price");
        assertEq(paid, 103_933_630_716_331_355, "batches of 1: wei paid");
    }

    /// batches of 5 credits drop the bid 2.5 percent, inside the launch gap
    function test_batchSeller5() public {
        (uint256 sold, uint256 paid) = _batchSeller(5);
        _logBatch(5, sold, paid);
        assertEq(sold, 60, "batches of 5: credits an hour at the opening price");
        assertEq(paid, 102_902_912_528_907_621, "batches of 5: wei paid");
    }

    /// batches of 10 credits drop the bid 4.9 percent, inside the launch gap
    function test_batchSeller10() public {
        (uint256 sold, uint256 paid) = _batchSeller(10);
        _logBatch(10, sold, paid);
        assertEq(sold, 60, "batches of 10: credits an hour at the opening price");
        assertEq(paid, 101_633_664_963_187_848, "batches of 10: wei paid");
    }

    /// batches of 19 credits drop the bid 9.1 percent, the largest batch inside the launch gap of 10 percent
    function test_batchSeller19() public {
        (uint256 sold, uint256 paid) = _batchSeller(19);
        _logBatch(19, sold, paid);
        assertEq(sold, 76, "batches of 19: credits an hour at the opening price");
        assertEq(paid, 125_877_567_966_787_262, "batches of 19: wei paid");
    }

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
        assertApproxEqRel(peakRate, expected, 1e-9 ether, "the peak is restated at the old half life, so it is unchanged now");
        assertEq(peakTime, block.timestamp, "the peak time is reset to now");
        assertLt(peakRate, peakBefore, "the restated peak is below the stored peak (it had decayed)");
    }

    /// a change that does not touch `peakHalfLife` leaves the remembered peak and its time where they are
    function test_setSettingsKeepingHalfLifeLeavesThePeak() public {
        vm.prank(owner);
        core.setRate(OPEN_RATE * 2);
        _warp(1 hours);
        (uint256 peakBefore, uint256 timeBefore) = _peak();
        Settings memory s = core.settings();
        s.saleFloorBps = 8_000;
        _setSettings(s);
        (uint256 peakRate, uint256 peakTime) = _peak();
        assertEq(peakRate, peakBefore, "the peak is untouched when the half life does not change");
        assertEq(peakTime, timeBefore, "the peak time is untouched");
    }

    /// the lazy climb is monotone in time between fills. the raw climb trajectory never falls: with a high ceiling, the
    /// longest peak half life (so the ceiling anchor barely decays over the window) and a large pot, neither the ceiling
    /// nor the clamp binds, so the price state is the raw climb and a later read is never below an earlier one, whatever
    /// the dump that preceded it. the clamped price following a decaying peak down is the intended behaviour and is not
    /// tested here
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
