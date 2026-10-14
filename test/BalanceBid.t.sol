// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ICreditScore, Mainnet, Settings} from "../src/interfaces/Interfaces.sol";

/// the rising balance token bid (decision 122). one credit's bid is `score * unitPerPoint * balanceRate() / 10_000`,
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
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 8_000; // floor 2_000
        _setSettings(s);
        assertEq(core.balanceRate(), 2_000, "reset to the new floor");
        uint256[] memory ids = _credits(user, 1);
        uint256 expect = _score(ids[0]) * UNIT * 2_000 / 10_000;
        assertEq(core.balanceBidOf(ids[0]), expect, "bid at the floor rate");
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before, expect, "paid the floor rate bid");
    }

    // promise: SPEC 4 a margin change that lowers the floor leaves the climbed rate unchanged
    function test_marginLowerDoesNotReset() public {
        Settings memory s = core.settings();
        s.balanceBidMarginBps = 8_000; // floor 2_000, resets the instance there
        _setSettings(s);
        _warp(1 days); // climb above 2_000
        uint256 r = core.balanceRate();
        assertGt(r, 2_000, "climbed above the raised floor");
        s.balanceBidMarginBps = 9_000; // floor 1_000, below the climbed rate: no reset
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
}
