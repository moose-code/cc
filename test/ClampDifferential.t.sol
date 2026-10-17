// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";

/// the eth price state clamp of adopt and the eth floor is the pages pot less the reserve (decision 158). main clamped
/// adopt, _moveEth and _ethFloorNow to the booked pot (c.ethPot): no reserve held back. this pins the new numbers at
/// launch settings with a booked pot, pending fee income and a nonzero reserve, and records main's booked-pot result
/// and the delta. the pages pot already counts pending income (decision 147); the new rule also holds back the reserve
/// (decision 155), so the three price-basis reads clamp exactly as the live eth bid does.
contract ClampDifferentialTest is Fixture {
    /// the booked pot the test funds, wei
    uint256 internal constant POT = 0.3 ether;
    /// the unbooked fee income the test adds, wei
    uint256 internal constant PENDING = 0.11 ether;

    function setUp() public override {
        super.setUp();
        // lift the rate cap and loosen the ceiling so the pot clamp, not the rate cap or the ceiling, is what the eth
        // price state settles at, the same setup test/Seaport.t.sol uses to drive the bid up
        Settings memory s = core.settings();
        s.rateCap = 2 ether;
        s.ceilBps = 30_000;
        s.idleLoosenBps = 2_000;
        s.reserveWei = 0.1 ether; // the launch reserve (decision 155), nonzero so the clamp holds it back
        _setSettings(s);
    }

    // promise: SPEC 4 adopt's cost basis and the eth floor clamp to the pages pot less the reserve (decision 158)
    function test_clampIsPagesPotLessReserve() public {
        // payeePpm 0 at launch, so the pot share of pending income is pending less the redeem-burn share only
        assertEq(core.settings().payeePpm, 0, "launch payeePpm is 0");

        vm.deal(address(this), address(this).balance + POT);
        core.fund{value: POT}(); // books any prior unbooked balance, then adds POT to ethPot
        vm.deal(address(core), address(core).balance + PENDING); // raw eth is unbooked fee income

        uint256 pot = core.ethPot();
        uint256 feeBps = core.settings().feeToRedeemBurnBps;
        uint256 pendingShare = PENDING - PENDING * feeBps / 10_000;
        uint256 pagesPot = pot + pendingShare; // _ethPagesPot with payeePpm 0
        uint256 reserve = core.reserve(); // reserveWei, the pile is empty
        uint256 clampNew = pagesPot - reserve;

        assertGt(reserve, 0, "the reserve is nonzero");
        assertGt(pendingShare, 0, "there is pending income");
        assertLt(clampNew, core.settings().rateCap, "the clamp binds below the rate cap");
        assertLt(core.floorRate(), clampNew, "the price state starts below the clamp");

        // warp until the eth price state climbs to the clamp; the ceiling grows with idle time past the clamp, so the
        // pot clamp is the binding constraint and the floor settles at it
        for (uint256 i; i < 2_000 && core.floorRate() < clampNew; ++i) {
            vm.warp(block.timestamp + 1 hours);
        }

        // new rule: the eth floor is the pages pot less the reserve
        assertEq(core.floorRate(), clampNew, "the eth floor is the pages pot less the reserve");

        // new rule: a 100-point credit the engine adopts books at the same clamp. adopt books the pending income first,
        // so its pages pot equals the booked pot, and the clamp is that pot less the reserve
        uint256[] memory ids = _credits(address(core), 1);
        _mockScore(ids[0], RATE_SCORE);
        core.adopt(ids);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(cost, clampNew, "the adopted cost basis is the pages pot less the reserve");

        // main's booked-pot rule: the clamp was ethPot with no reserve held back, which after the book equals the pages
        // pot. so main would price both reads at pagesPot, the delta is the reserve
        uint256 mainClamp = pagesPot;
        assertEq(mainClamp - clampNew, reserve, "the delta from main's booked-pot rule is the reserve");
        console.log("pages pot (wei):", pagesPot);
        console.log("reserve (wei):", reserve);
        console.log("new clamp, eth floor and adopt basis (wei):", clampNew);
        console.log("main booked-pot clamp (wei):", mainClamp);
        console.log("delta, the reserve held back (wei):", reserve);
    }
}
