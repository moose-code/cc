// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {ICreditScore, Mainnet} from "../src/interfaces/Interfaces.sol";

/// the balance bid never pays below its floor. when the module's available() is under the floor par of a credit, the
/// per-credit rate clamp falls below the floor `10_000 - balanceBidMarginBps`; `sellForBalance` refuses the fill with
/// `PotTooSmall` and `balanceBidOf(id)` reports the floor payout, never a sub-floor number and never 0
contract BalanceFloorTest is Fixture {
    address internal user;

    function setUp() public override {
        super.setUp();
        user = _user("floor.user");
        _enterPhase2();
    }

    function _score(uint256 id) internal view returns (uint256) {
        return ICreditScore(Mainnet.CREDIT_SCORE).scoreOf(CREDITS.seedOf(id), CREDITS.timestampOf(id));
    }

    // promise: SPEC 1 the balance bid refuses a fill whose available-clamped rate is below the floor
    function test_sellForBalanceRefusesBelowFloor() public {
        uint256 floorBps = 10_000 - core.settings().balanceBidMarginBps;
        uint256 refScore = core.settings().refScore;
        // available at half the floor par of a refScore credit: the rate clamp is floorBps / 2, under the floor
        mod.setAvailable(refScore * UNIT * floorBps / 10_000 / 2);

        uint256[] memory ids = _credits(user, 1);
        uint256 floorPay = _score(ids[0]) * UNIT * floorBps / 10_000;
        assertEq(core.balanceBidOf(ids[0]), floorPay, "balanceBidOf reports the floor payout");
        assertGt(core.balanceBidOf(ids[0]), 0, "never 0 for a credit the module cannot pay the floor for");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("PotTooSmall()"));
        core.sellForBalance(ids);
    }

    // promise: SPEC 1 with available() at the floor par of a refScore credit the clamp equals the floor, so the fill
    // runs at the floor rate
    function test_atRefScoreFloorParRunsAtFloor() public {
        uint256 floorBps = 10_000 - core.settings().balanceBidMarginBps;
        uint256 refScore = core.settings().refScore;
        mod.setAvailable(refScore * UNIT * floorBps / 10_000); // clamp is exactly the floor

        // a credit of score at or below refScore so the running total fits available at the floor rate
        uint256[] memory ids = _creditAtMostRefScore(user, refScore);
        uint256 floorPay = _score(ids[0]) * UNIT * floorBps / 10_000;
        uint256 before = xt.balanceOf(user);
        vm.prank(user);
        core.sellForBalance(ids);
        assertEq(xt.balanceOf(user) - before, floorPay, "ran at the floor rate at the floor par");
    }

    // promise: SPEC 1 an available far below the floor par refuses the batch with PotTooSmall, never a panic
    /// the state the InvariantsSalePhase2Deep counterexample reached: available a few wei (8_000_001), orders of
    /// magnitude below a credit's floor par, with the bid on and a multi credit batch. the rate clamp collapses to
    /// zero, below the floor, so `sellForBalance` refuses the whole batch
    function test_sellForBalanceRefusesWithTinyAvailable() public {
        mod.setAvailable(8_000_001);
        uint256[] memory ids = _credits(user, 3);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("PotTooSmall()"));
        core.sellForBalance(ids);
    }

    /// one credit owned by `who` whose score is at most `cap`, with the core approved
    function _creditAtMostRefScore(address who, uint256 cap) internal returns (uint256[] memory ids) {
        for (uint256 i; i < 64; ++i) {
            ids = _credits(who, 1);
            if (_score(ids[0]) <= cap) return ids;
        }
        revert("no credit at or below refScore found");
    }
}
