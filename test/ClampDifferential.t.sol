// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Settings, RATE_SCORE} from "../src/interfaces/Interfaces.sol";

/// The price state climbs only against booked ETH above reserve. Pending fee income widens the executable bid clamp,
/// but has no known arrival time and cannot raise the funded climb limit before a book.
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

    // promise: the ETH floor and adopted cost basis use the booked funded climb limit, while the pending fee share
    // widens only the live bid's executable room until a book
    function test_bookedClimbAndPendingReadLimitsStaySeparate() public {
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
        // both limits include the purchase royalty; only the read can use pending fees before a book
        uint256 bookedClamp = (pot - reserve) * 10_000 / (10_000 + core.settings().buyToArtistBps);
        uint256 readClamp = (pagesPot - reserve) * 10_000 / (10_000 + core.settings().buyToArtistBps);

        assertGt(reserve, 0, "the reserve is nonzero");
        assertGt(pendingShare, 0, "there is pending income");
        assertLt(readClamp, core.settings().rateCap, "the read clamp binds below the rate cap");
        assertLt(bookedClamp, readClamp, "pending income widens the read room only");
        assertLt(core.floorRate(), bookedClamp, "the price state starts below the booked clamp");

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        core.setRate(0.25 ether);
        assertEq(core.ethRate(), 0.25 ether, "pending ETH makes the posted price payable before booking");
        vm.deal(address(core), address(core).balance - PENDING);
        assertEq(core.ethRate(), bookedClamp, "without pending ETH the same price is clamped to booked room");
        vm.revertToState(snap);

        // the funded climb stops at booked room even while the pending-inclusive read has more room
        for (uint256 i; i < 2_000 && core.floorRate() < bookedClamp; ++i) {
            vm.warp(block.timestamp + 1 hours);
        }

        assertEq(core.floorRate(), bookedClamp, "the eth floor uses booked ETH above reserve");
        assertEq(core.ethRate(), bookedClamp, "the live bid has room for the booked price and royalty");

        // adopt books pending income before recording the cost, but does not credit its prior unbooked time
        uint256[] memory ids = _credits(address(core), 1);
        _mockScore(ids[0], RATE_SCORE);
        core.adopt(ids);
        (, uint256 cost,) = core.creditInfo(ids[0]);
        assertEq(
            cost,
            bookedClamp + bookedClamp * core.settings().buyToArtistBps / 10_000,
            "the adopted basis is the funded price plus the royalty"
        );

        console.log("pages pot (wei):", pagesPot);
        console.log("reserve (wei):", reserve);
        console.log("booked funded climb limit (wei):", bookedClamp);
        console.log("pending-inclusive read limit (wei):", readClamp);
    }
}
