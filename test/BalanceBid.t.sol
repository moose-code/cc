// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";

/// the rising balance token bid. one credit's bid is `score * unitPerPoint * balanceRate() / 10_000`,
/// where `balanceRate()` is the balance instance price state in bps of par, floored at `10_000 - balanceBidMarginBps`,
/// capped at 10_000 so the payout never exceeds par, climbed by the eth bid's climb and dropped per credit by the eth
/// bid's drop. the instance shares the eth bid's climb and drop settings
contract BalanceBidTest is Fixture {
    address internal user;

    function setUp() public override {
        super.setUp();
        user = _user("bal.user");
        _enterPhase2();
    }

    function _floorBps() internal view returns (uint256) {
        return 10_000 - core.settings().balanceBidMarginBps;
    }

    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    // promise: SPEC 4 a margin change that raises the floor resets the instance to that floor, which is its opening
    // value, and the bid pays that floor rate in the same block
    function test_resetToFloorAndPaysFloor() public {
        // the launch floor is 9_000; margin 0 raises it to 10_000 (par), above the stored rate, so the instance resets
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 0; // floor 10_000
        _setSettings(s);
        assertEq(core.balanceRate(), 10_000, "reset to the new floor");
        uint256[] memory ids = _credits(user, 1);
        uint256 expect = _score(ids[0]) * UNIT * 10_000 / 10_000;
        assertEq(core.balanceBidOf(ids[0]), expect, "bid at the floor rate");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before, expect, "paid the floor rate bid");
    }

    // promise: SPEC 4 a margin change that lowers the floor leaves the climbed rate unchanged
    function test_marginLowerDoesNotReset() public {
        _warp(2 days); // climb above the launch floor 9_000
        uint256 r = core.balanceRate();
        assertGt(r, 9_000, "climbed above the launch floor");
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 2_000; // floor 8_000, below the climbed rate: no reset
        _setSettings(s);
        assertEq(core.balanceRate(), r, "the climbed rate is unchanged by a lower floor");
    }

    // promise: SPEC 4 the balance rate climbs with time and stops at par (10_000)
    function test_climbsToParAndStops() public {
        uint256 r0 = core.balanceRate();
        _warp(2 days);
        uint256 r1 = core.balanceRate();
        assertGt(r1, r0, "the rate climbs with time");
        assertLe(r1, 10_000, "never above par");
        _warp(3650 days);
        assertEq(core.balanceRate(), 10_000, "climbs to par and stops at the cap");
    }

    // promise: SPEC 4 balanceBidOf is score * unit * balanceRate() / 10_000
    function test_balanceBidOfIdentity() public {
        _warp(6 hours);
        uint256[] memory ids = _credits(user, 1);
        uint256 rate = core.balanceRate();
        assertEq(core.balanceBidOf(ids[0]), _score(ids[0]) * UNIT * rate / 10_000, "balanceBidOf identity");
    }

    // promise: SPEC 4 each credit drops the balance rate and the rate never falls below the floor
    function test_dropLowersRateAndHoldsFloor() public {
        _warp(1 days);
        uint256 before = core.balanceRate();
        assertGt(before, _floorBps(), "climbed above the floor");
        uint256[] memory ids = _credits(user, 1);
        vm.prank(user);
        core.sellForBalance(ids);
        uint256 now_ = core.balanceRate();
        assertLt(now_, before, "a fill drops the rate");
        assertGe(now_, _floorBps(), "never below the floor");
    }

    /// @dev the balance rate after one idle minute at a module `available` sized to `pages` pages of par, starting from
    /// the floor. snapshots so each measurement climbs from the same floored state
    function _balanceClimbAfterMinute(uint256 available) internal returns (uint256 r) {
        uint256 snap = vm.snapshotState();
        mod.setAvailable(available);
        _warp(60);
        r = core.balanceRate();
        vm.revertToState(snap);
    }

    // promise: SPEC 4 decision 128 variant d: the balance climb does not scale with available (only the loosening does)
    /// the balance instance shares the eth rule: the per minute climb is unscaled, so one page of available and four
    /// pages climb the same (climbPerMinBps 50, 0.5 percent a minute). the multiplier scales the ceiling loosening,
    /// which the par cap (10_000) bounds in the narrow [floor, par] band
    function test_balanceClimbUnscaledByAvailable() public {
        uint256 floor = _floorBps();
        // one page at par is 80 * refScore * UNIT; available sized so availBpsRaw / (80 * floor) is 1 and 4 pages
        uint256 onePage = 80 * uint256(core.settings().refScore) * UNIT * floor / 10_000;
        assertApproxEqAbs(_balanceClimbAfterMinute(onePage), floor * 10_050 / 10_000, 1, "one page climbs at 1x");
        assertApproxEqAbs(
            _balanceClimbAfterMinute(onePage * 4), floor * 10_050 / 10_000, 1, "four pages climb at the same 1x"
        );
    }

    // promise: SPEC 4 a module answering a huge available() never overflows the pages pot or freezes setSettings
    /// `_toBpsRaw` saturates `available()` before the bps multiply, so a module reporting `type(uint256).max` (a common
    /// "unlimited" answer) keeps the multiplier at its 4x cap and does not panic `balanceRate`, `balanceBidOf`,
    /// `sellForBalance` or `setSettings` (the `_balanceCheckpointNow` path that is the only way to turn the bid off)
    function test_hugeAvailableDoesNotOverflowOrFreeze() public {
        mod.setAvailable(type(uint256).max);
        uint256 r = core.balanceRate();
        assertGt(r, 0, "balanceRate answers");
        assertLe(r, 10_000, "at most par");
        uint256[] memory ids = _credits(user, 1);
        assertGt(core.balanceBidOf(ids[0]), 0, "balanceBidOf answers");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertGt(xt.balanceOf(user) - before, 0, "sellForBalance paid");
        // setSettings checkpoints the balance instance while the bid is on; it must not revert
        Settings memory s = core.settings();
        s.climbPerMinBps = 123;
        _setSettings(s);
        assertEq(core.settings().climbPerMinBps, 123, "setSettings landed");
    }

    // promise: SPEC 4 the payout never exceeds par: score * unit at the 10_000 cap
    function test_payoutNeverAbovePar() public {
        _warp(3650 days); // the rate is at the 10_000 cap
        uint256[] memory ids = _credits(user, 1);
        uint256 par = _score(ids[0]) * UNIT;
        assertEq(core.balanceBidOf(ids[0]), par, "at the cap the bid equals par");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before, par, "paid exactly par, never above");
    }

    // promise: a raised balance cap is actually payable above par and lowering it clamps immediately
    function test_configurableCapPaysAbovePar() public {
        Settings memory s = core.settings();
        s.balanceBidCapBps = 20_000;
        _setSettings(s);
        _warp(2 days);
        assertEq(core.balanceRate(), 20_000);
        uint256[] memory ids = _credits(user, 1);
        uint256 expected = _score(ids[0]) * UNIT * 2;
        uint256 before_ = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before_, expected);
        s.balanceBidCapBps = 10_000;
        _setSettings(s);
        assertLe(core.balanceRate(), 10_000);
    }

    // promise: the balance pages conversion honors both rate and multiplier caps without truncating huge availability
    function test_balanceMultiplierAboveParAndHugeAvailable() public {
        Settings memory s = core.settings();
        s.balanceBidCapBps = 50_000;
        _setSettings(s);
        _warp(2 days);
        // Balance Rate starts at slot 32; its anchor's last fill rate is slot 34.
        vm.store(address(core), bytes32(uint256(34)), bytes32(uint256(20_000)));
        vm.store(address(core), bytes32(uint256(37)), bytes32(uint256(20_000)));
        uint256 denom = uint256(s.refScore) * UNIT;
        mod.setAvailable(500 * denom);
        // At 500 pages-worth of par a 2x fill buys 250 pages, a 3.125x loosening multiplier.
        vm.store(address(core), bytes32(uint256(32)), bytes32(uint256(50_000)));
        vm.store(
            address(core),
            bytes32(uint256(33)),
            bytes32(uint256(uint64(block.timestamp)) | (uint256(uint64(block.timestamp - 600)) << 64))
        );
        uint256 expectedCeiling = 20_000 * (10_000 + 600 * 31_250 / 10_000) * 11_000 / 1e8;
        assertEq(expectedCeiling, 26_125);
        assertEq(core.balanceRate(), expectedCeiling);
        mod.setAvailable(type(uint256).max);
        assertEq(core.balanceRate(), 27_280);
        uint256[] memory ids = _credits(user, 1);
        assertGt(core.balanceBidOf(ids[0]), 0);
    }

    // promise: the full margin endpoint remains a zero bid until the owner restores a positive floor
    function test_zeroFloorDoesNotInventAPositiveBid() public {
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 10_000;
        s.balanceBidOn = false;
        _setSettings(s);
        s.balanceBidOn = true;
        _setSettings(s);
        _warp(1 days);
        assertEq(core.balanceRate(), 0);
        s.balanceBidMarginBps = 9_000;
        _setSettings(s);
        assertEq(core.balanceRate(), 1_000);
    }
}
